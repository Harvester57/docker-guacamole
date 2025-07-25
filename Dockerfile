# Cf. https://hub.docker.com/_/debian
FROM debian:bullseye@sha256:25c0cab214b810db1b3c8adef5a12a92596979abddf86bb364e8d9c9d111df9f AS builder

ARG ARCH=amd64
ARG GUACAMOLE_HOME=/app/guacamole
# https://guacamole.apache.org/releases/
ARG GUAC_VER=1.6.0
ARG DEBIAN_FRONTEND=noninteractive

WORKDIR ${GUACAMOLE_HOME}

RUN \
  apt-get update && \
  # Needed to handle the HTTPS certs and import third-party repos
  apt-get install curl ca-certificates checkinstall -y --no-install-recommends && \
  update-ca-certificates

# Install dependencies
RUN \
  apt-get install -y \
  libcairo2-dev libjpeg62-turbo-dev libpng-dev \
  libossp-uuid-dev libavcodec-dev libavutil-dev libavformat-dev \
  libswscale-dev freerdp2-dev libfreerdp-client2-2 libpango1.0-dev \
  libssh2-1-dev libvncserver-dev \
  libssl-dev libvorbis-dev libwebp-dev libwebsockets-dev \
  ghostscript build-essential --no-install-recommends && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

# Link FreeRDP to where guac expects it to be
RUN [ "$ARCH" = "amd64" ] && ln -s /usr/local/lib/freerdp /usr/lib/x86_64-linux-gnu/freerdp || exit 0

# Build guacamole-server
RUN \
  curl -k -SLO "https://dlcdn.apache.org/guacamole/${GUAC_VER}/source/guacamole-server-${GUAC_VER}.tar.gz" && \
  tar -xzf guacamole-server-${GUAC_VER}.tar.gz
  
WORKDIR /app/guacamole/guacamole-server-${GUAC_VER}

RUN \
  export CFLAGS="-O3 -pipe -g0 -s -march=broadwell -mtune=broadwell -fstack-protector-all -D_FORTIFY_SOURCE=2 -Wp,-D_FORTIFY_SOURCE=2 -fstack-clash-protection -flto=4 -fPIE -pie" && \
  export LDFLAGS="-Wl,-z,relro -Wl,-z,now -Wl,--as-needed -Wl,-z,defs -Wl,-z,noexecheap -Wl,-O1 -Wl,-z,noexecstack -Wl,-z,separate-code -Wl,--strip-all" && \
  ./configure --disable-guacenc --disable-guaclog --enable-static --disable-kubernetes --with-rdp --with-vnc --with-ssh --without-telnet && \
  make -j$(getconf _NPROCESSORS_ONLN) && \
  checkinstall --install=no --default && \
  cp *.deb / && ls /
  
# Multi-stage build
# Cf. https://github.com/docker-library/docs/blob/master/tomcat/README.md#supported-tags-and-respective-dockerfile-links
FROM tomcat:11-jdk21

ARG ARCH=amd64
  # https://guacamole.apache.org/releases/
ARG GUAC_VER=1.6.0
ARG GUACAMOLE_HOME=/app/guacamole
ARG PG_MAJOR=9.6
ARG PGDATA=/config/postgres
ARG POSTGRES_USER=guacamole
ARG POSTGRES_DB=guacamole_db
# https://jdbc.postgresql.org/download/
ARG JDBC_VER=42.7.7
# https://github.com/just-containers/s6-overlay/releases
ARG OVERLAY_VER=2.2.0.3
ARG DEBIAN_FRONTEND=noninteractive

WORKDIR ${GUACAMOLE_HOME}

# Link FreeRDP to where guac expects it to be
RUN [ "$ARCH" = "amd64" ] && ln -s /usr/local/lib/freerdp /usr/lib/x86_64-linux-gnu/freerdp || exit 0

RUN \
  apt-get update && \
  # Needed to handle the HTTPS certs and import third-party repos
  apt-get install curl gnupg2 ca-certificates --no-install-recommends -y && \
  update-ca-certificates && \
  apt-get dist-upgrade -y && \
  apt-get clean && \
  rm -rf /var/lib/apt/lists/*

# Apply the s6-overlay
RUN \
  curl -k -SLO "https://github.com/just-containers/s6-overlay/releases/download/v${OVERLAY_VER}/s6-overlay-${ARCH}.tar.gz" && \
  tar -xzf s6-overlay-${ARCH}.tar.gz -C / && \
  tar -xzf s6-overlay-${ARCH}.tar.gz -C /usr ./bin && \
  rm -rf s6-overlay-${ARCH}.tar.gz && \
  mkdir -p ${GUACAMOLE_HOME} \
  ${GUACAMOLE_HOME}/lib \
  ${GUACAMOLE_HOME}/extensions

# Install PostgreSQL and required dependencies
COPY postgresql.list /etc/apt/sources.list.d
RUN apt update
RUN apt install -y \
  postgresql-${PG_MAJOR} libcairo2 libfreerdp2-2 libfreerdp-server2-2 libfreerdp-client2-2 \
  libfreerdp-shadow-subsystem2-2 libfreerdp-shadow2-2 libvncserver1 libvncclient1 --no-install-recommends
RUN apt-get clean
RUN rm -rf /var/lib/apt/lists/*

# Install Guacamole deb package imported from builder
COPY --from=BUILDER /*.deb /
RUN \
  dpkg -i /*.deb && \
  ldconfig

# Install guacamole-client and postgres auth adapter
RUN \
  set -x && \
  rm -rf ${CATALINA_HOME}/webapps/ROOT && \
  curl -k -SLo ${CATALINA_HOME}/webapps/ROOT.war "http://apache.org/dyn/closer.cgi?action=download&filename=guacamole/${GUAC_VER}/binary/guacamole-${GUAC_VER}.war" && \
  curl -k -SLo ${GUACAMOLE_HOME}/lib/postgresql-${JDBC_VER}.jar "https://jdbc.postgresql.org/download/postgresql-${JDBC_VER}.jar" && \
  curl -k -SLO "http://apache.org/dyn/closer.cgi?action=download&filename=guacamole/${GUAC_VER}/binary/guacamole-auth-jdbc-${GUAC_VER}.tar.gz" && \
  tar -xzf guacamole-auth-jdbc-${GUAC_VER}.tar.gz && \
  cp -R guacamole-auth-jdbc-${GUAC_VER}/postgresql/guacamole-auth-jdbc-postgresql-${GUAC_VER}.jar ${GUACAMOLE_HOME}/extensions/ && \
  cp -R guacamole-auth-jdbc-${GUAC_VER}/postgresql/schema ${GUACAMOLE_HOME}/ && \
  rm -rf guacamole-auth-jdbc-${GUAC_VER} guacamole-auth-jdbc-${GUAC_VER}.tar.gz

# Add optional extensions
RUN \
  set -xe && \
  mkdir ${GUACAMOLE_HOME}/extensions-available && \
  for i in auth-ldap auth-openid auth-totp; do \
  echo "https://dlcdn.apache.org/guacamole/${GUAC_VER}/binary/guacamole-${i}-${GUAC_VER}.tar.gz" && \
  curl -k -SLO "http://apache.org/dyn/closer.cgi?action=download&filename=guacamole/${GUAC_VER}/binary/guacamole-${i}-${GUAC_VER}.tar.gz" && \
  tar -xzf guacamole-${i}-${GUAC_VER}.tar.gz && \
  cp guacamole-${i}-${GUAC_VER}/guacamole-${i}-${GUAC_VER}.jar ${GUACAMOLE_HOME}/extensions-available/ && \
  rm -rf guacamole-${i}-${GUAC_VER} guacamole-${i}-${GUAC_VER}.tar.gz \
  ;done

ENV PATH=/usr/lib/postgresql/${PG_MAJOR}/bin:$PATH
ENV GUACAMOLE_HOME=/config/guacamole

WORKDIR /config

COPY root /

EXPOSE 8080

ENTRYPOINT [ "/init" ]
