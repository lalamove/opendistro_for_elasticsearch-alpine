FROM quay.io/lalamove/zulu-openjdk-alpine:11.0.2 AS jlinked
RUN ["/opt/openjdk-11/bin/jlink", "--compress=2", \
     "--module-path", "/opt/openjdk-11/jmods", \
     "--add-modules", "java.base,java.logging,java.management,java.xml,java.desktop,java.compiler,java.naming,java.rmi,java.scripting,java.sql,java.security.jgss,java.security.sasl,java.xml.crypto,java.datatransfer", \
     "--output", "/jlinked"]

FROM quay.io/lalamove/zulu-openjdk-alpine:11.0.2 AS alertingbuild
RUN apk add --update sudo bash readline git
RUN mkdir /scratch
WORKDIR /scratch
RUN git clone https://github.com/mikn/alerting.git alerting
WORKDIR /scratch/alerting
# Need to use a non-root builder here because tests start an elasticsearch server which fails if it is run as root
RUN adduser -h /scratch/alerting -D builder && chown builder: . -R
RUN sudo -E -u builder ./gradlew build
RUN mkdir /scratch/plugin
WORKDIR /scratch/plugin
RUN unzip /scratch/alerting/alerting/build/distributions/opendistro_alerting-0.7.0.0-SNAPSHOT.zip

FROM quay.io/lalamove/zulu-openjdk-alpine:11.0.2 AS securitybuild
RUN apk add --update linux-headers build-base autoconf automake libtool apr-util apr-util-dev git cmake ninja go openssl openssl-dev sudo
ENV NETTY_TCNATIVE_TAG netty-tcnative-parent-2.0.22.Final
ENV MAVEN_VERSION 3.6.0
ENV MAVEN_HOME /usr/share/maven

RUN cd /usr/share ; \
        wget -q http://archive.apache.org/dist/maven/maven-3/$MAVEN_VERSION/binaries/apache-maven-$MAVEN_VERSION-bin.tar.gz -O - | tar xzf - ;\
        mv /usr/share/apache-maven-$MAVEN_VERSION /usr/share/maven ;\
        ln -s /usr/share/maven/bin/mvn /usr/bin/mvn
RUN mkdir /scratch

WORKDIR /scratch
RUN git clone https://github.com/netty/netty-tcnative; \
        cd netty-tcnative; \
        git checkout tags/$NETTY_TCNATIVE_TAG
COPY docker_settings.xml .

WORKDIR netty-tcnative

RUN mvn -s /scratch/docker_settings.xml clean install -pl openssl-dynamic -am

WORKDIR /scratch
RUN git clone https://github.com/opendistro-for-elasticsearch/security-parent.git
WORKDIR security-parent
RUN mvn -s /scratch/docker_settings.xml clean install

WORKDIR /scratch
RUN git clone https://github.com/mikn/security-ssl.git
WORKDIR /scratch/security-ssl
RUN mvn -s /scratch/docker_settings.xml clean install

WORKDIR /scratch
RUN git clone https://github.com/mikn/security.git
WORKDIR /scratch/security
RUN mvn -s /scratch/docker_settings.xml clean install

WORKDIR /scratch
RUN git clone https://github.com/mikn/security-advanced-modules.git
WORKDIR /scratch/security-advanced-modules
RUN mvn -s /scratch/docker_settings.xml clean install

WORKDIR /scratch/security
RUN mvn -s /scratch/docker_settings.xml -Dmaven.test.skip=true -P advanced package
RUN mkdir /scratch/plugin
WORKDIR /scratch/plugin
RUN unzip /scratch/security/target/releases/opendistro_security-0.7.0.0.zip
RUN cp /scratch/netty-tcnative/openssl-dynamic/target/netty-tcnative-2.0.22.Final-linux-x86_64.jar /scratch/plugin/

FROM alpine:3.9

LABEL maintainer "https://github.com/blacktop"

RUN apk add --no-cache su-exec

ENV JAVA_HOME /opt/openjdk-11
ENV PATH $JAVA_HOME/bin:$PATH

ENV VERSION 6.6.2
ENV DOWNLOAD_URL "https://artifacts.elastic.co/downloads/elasticsearch"
ENV ES_TARBAL "${DOWNLOAD_URL}/elasticsearch-oss-${VERSION}.tar.gz"
ENV ES_TARBALL_ASC "${DOWNLOAD_URL}/elasticsearch-oss-${VERSION}.tar.gz.asc"
ENV EXPECTED_SHA_URL "${DOWNLOAD_URL}/elasticsearch-oss-${VERSION}.tar.gz.sha512"
#ENV ES_TARBALL_SHA "0e536ff760673dd740f790f1b0c01d984bf989a4a9ad3c4fe998de4f824330ce0d5ea18f04421a8648af719aabd25a4393f90182079186e48cef539b5621914c"
ENV GPG_KEY "46095ACC8548582C1A2699A9D27D666CD88E42B4"

COPY --from=jlinked /jlinked $JAVA_HOME

RUN apk add -u bash openssl apr \
  && apk add -t .build-deps wget ca-certificates gnupg \
  && set -ex \
  && cd /tmp \
  && echo "===> Install Elasticsearch..." \
  && wget --progress=bar:force -O elasticsearch.tar.gz "$ES_TARBAL"; \
  if [ "$ES_TARBALL_SHA" ]; then \
  echo "$ES_TARBALL_SHA *elasticsearch.tar.gz" | sha512sum -c -; \
  fi; \
  if [ "$ES_TARBALL_ASC" ]; then \
  wget --progress=bar:force -O elasticsearch.tar.gz.asc "$ES_TARBALL_ASC"; \
  export GNUPGHOME="$(mktemp -d)"; \
  ( gpg --keyserver ha.pool.sks-keyservers.net --recv-keys "$GPG_KEY" \
  || gpg --keyserver pgp.mit.edu --recv-keys "$GPG_KEY" \
  || gpg --keyserver keyserver.pgp.com --recv-keys "$GPG_KEY" ); \
  gpg --batch --verify elasticsearch.tar.gz.asc elasticsearch.tar.gz; \
  rm -rf "$GNUPGHOME" elasticsearch.tar.gz.asc || true; \
  fi; \
  tar -xf elasticsearch.tar.gz \
  && ls -lah \
  && mv elasticsearch-$VERSION /usr/share/elasticsearch \
  && adduser -D -h /usr/share/elasticsearch elasticsearch \
  && echo "===> Creating Elasticsearch Paths..." \
  && for path in \
      /usr/share/elasticsearch/data \
      /usr/share/elasticsearch/logs \
      /usr/share/elasticsearch/config \
      /usr/share/elasticsearch/config/scripts \
      /usr/share/elasticsearch/tmp \
      /usr/share/elasticsearch/plugins \
  ; do \
      mkdir -p "$path"; \
      chown -R elasticsearch:elasticsearch "$path"; \
  done \
  && /usr/share/elasticsearch/bin/elasticsearch-plugin install -b https://distfiles.compuscene.net/elasticsearch/elasticsearch-prometheus-exporter-6.6.2.0.zip \
  && rm -rf /tmp/* \
  && apk del --purge .build-deps \
  && rm -rf /var/cache/apk/*

COPY config/elastic /usr/share/elasticsearch/config
COPY config/logrotate /etc/logrotate.d/elasticsearch
COPY elastic-entrypoint.sh /
RUN chmod +x /elastic-entrypoint.sh
COPY docker-healthcheck /usr/local/bin/

WORKDIR /usr/share/elasticsearch

RUN mkdir plugins/opendistro_alerting
COPY --chown=elasticsearch --from=alertingbuild /scratch/plugin /usr/share/elasticsearch/plugins/opendistro_alerting

RUN mkdir plugins/opendistro_security
COPY --chown=elasticsearch --from=securitybuild /scratch/plugin /usr/share/elasticsearch/plugins/opendistro_security

ENV PATH /usr/share/elasticsearch/bin:$PATH
ENV ES_TMPDIR /usr/share/elasticsearch/tmp

VOLUME ["/usr/share/elasticsearch/data"]

EXPOSE 9200 9300
ENTRYPOINT ["/elastic-entrypoint.sh"]
CMD ["elasticsearch"]

# HEALTHCHECK CMD ["docker-healthcheck"]
