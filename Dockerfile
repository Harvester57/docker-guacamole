# Cf. https://github.com/docker-library/docs/blob/master/tomcat/README.md#supported-tags-and-respective-dockerfile-links
FROM tomcat:9.0.62-jdk17

ENV ARCH=amd64 \
  # https://guacamole.apache.org/releases/
  GUAC_VER=1.4.0 \
  GUACAMOLE_HOME=/app/guacamole \
  PG_MAJOR=9.6 \
  PGDATA=/config/postgres \
  POSTGRES_USER=guacamole \
  POSTGRES_DB=guacamole_db \
  # https://jdbc.postgresql.org/download.html#current
  JDBC_VER=42.3.3 \
  # https://github.com/just-containers/s6-overlay/releases
  OVERLAY_VER=2.2.0.3

WORKDIR ${GUACAMOLE_HOME}

RUN \
  apt-get update && \
  apt-get dist-upgrade -y && \
  # Needed to handle the HTTPS certs and import third-party repos
  apt-get install gnupg2 ca-certificates checkinstall -y && \
  update-ca-certificates

# Install dependencies
RUN \
  apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 7FCC7D46ACCC4CF8 && \
  apt-get update && apt-get install -y \
  libcairo2-dev libjpeg62-turbo-dev libpng-dev \
  libossp-uuid-dev libavcodec-dev libavutil-dev libavformat-dev \
  libswscale-dev freerdp2-dev libfreerdp-client2-2 libpango1.0-dev \
  libssh2-1-dev libtelnet-dev libvncserver-dev \
  libpulse-dev libssl-dev libvorbis-dev libwebp-dev libwebsockets-dev \
  ghostscript postgresql-${PG_MAJOR} build-essential --no-install-recommends && \
  apt-get clean && \ 
  rm -rf /var/lib/apt/lists/*

# Link FreeRDP to where guac expects it to be
RUN [ "$ARCH" = "amd64" ] && ln -s /usr/local/lib/freerdp /usr/lib/x86_64-linux-gnu/freerdp || exit 0

# Build guacamole-server
RUN \
  curl -k -SLO "http://apache.org/dyn/closer.cgi?action=download&filename=guacamole/${GUAC_VER}/source/guacamole-server-${GUAC_VER}.tar.gz" && \
  tar -xzf guacamole-server-${GUAC_VER}.tar.gz && \
  cd guacamole-server-${GUAC_VER} && \
  export CFLAGS="-O3 -pipe -g0 -s -march=broadwell -mtune=broadwell -fstack-protector-all -D_FORTIFY_SOURCE=2 -Wp,-D_FORTIFY_SOURCE=2 -fstack-clash-protection -flto=4 -fPIE -pie" && \
  export LDFLAGS="-Wl,-z,relro -Wl,-z,now -Wl,--as-needed -Wl,-z,defs -Wl,-z,noexecheap -Wl,-O1 -Wl,-z,noexecstack -Wl,-z,separate-code -Wl,--strip-all" && \
  ./configure && \
  make -j$(getconf _NPROCESSORS_ONLN) && \
  checkinstall --install=no --default && \
  cp *.deb / && ls /
  
# Multi-stage build
FROM tomcat:9.0.62-jdk17

ENV ARCH=amd64 \
  # https://guacamole.apache.org/releases/
  GUAC_VER=1.4.0 \
  GUACAMOLE_HOME=/app/guacamole \
  PG_MAJOR=9.6 \
  PGDATA=/config/postgres \
  POSTGRES_USER=guacamole \
  POSTGRES_DB=guacamole_db \
  # https://jdbc.postgresql.org/download.html#current
  JDBC_VER=42.3.3 \
  # https://github.com/just-containers/s6-overlay/releases
  OVERLAY_VER=2.2.0.3

WORKDIR ${GUACAMOLE_HOME}

# Link FreeRDP to where guac expects it to be
RUN [ "$ARCH" = "amd64" ] && ln -s /usr/local/lib/freerdp /usr/lib/x86_64-linux-gnu/freerdp || exit 0

RUN \
  apt-get update && \
  apt-get dist-upgrade -y && \
  # Needed to handle the HTTPS certs and import third-party repos
  apt-get install gnupg2 ca-certificates checkinstall -y && \
  update-ca-certificates

# Apply the s6-overlay
RUN \
  curl -k -SLO "https://github.com/just-containers/s6-overlay/releases/download/v${OVERLAY_VER}/s6-overlay-${ARCH}.tar.gz" && \
  tar -xzf s6-overlay-${ARCH}.tar.gz -C / && \
  tar -xzf s6-overlay-${ARCH}.tar.gz -C /usr ./bin && \
  rm -rf s6-overlay-${ARCH}.tar.gz && \
  mkdir -p ${GUACAMOLE_HOME} \
  ${GUACAMOLE_HOME}/lib \
  ${GUACAMOLE_HOME}/extensions

COPY postgresql.list /etc/apt/sources.list.d
COPY --from=0 /*.deb /

RUN \
  apt-key adv --keyserver keyserver.ubuntu.com --recv-keys 7FCC7D46ACCC4CF8 && \
  apt-get update && apt-get install -y \
  postgresql-${PG_MAJOR} --no-install-recommends && \
  apt-get clean && \ 
  rm -rf /var/lib/apt/lists/*

# Install Guacamole deb package imported from builder
RUN \
  dpkg -i /*.deb

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
  for i in auth-ldap auth-duo auth-header auth-cas auth-openid auth-quickconnect auth-totp; do \
  echo "http://apache.org/dyn/closer.cgi?action=download&filename=guacamole/${GUAC_VER}/binary/guacamole-${i}-${GUAC_VER}.tar.gz" && \
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
