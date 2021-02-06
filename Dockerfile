FROM tomcat:9.0.43-jdk15

ENV ARCH=amd64 \
  # https://guacamole.apache.org/releases/
  GUAC_VER=1.3.0 \
  GUACAMOLE_HOME=/app/guacamole \
  PG_MAJOR=9.6 \
  PGDATA=/config/postgres \
  POSTGRES_USER=guacamole \
  POSTGRES_DB=guacamole_db \
  # https://jdbc.postgresql.org/download.html#current
  JDBC_VER=42.2.18 \
  # https://github.com/just-containers/s6-overlay/releases
  OVERLAY_VER=2.2.0.1 

# Apply the s6-overlay
RUN curl -SLO "https://github.com/just-containers/s6-overlay/releases/download/v${OVERLAY_VER}/s6-overlay-${ARCH}.tar.gz" \
  && tar -xzf s6-overlay-${ARCH}.tar.gz -C / \
  && tar -xzf s6-overlay-${ARCH}.tar.gz -C /usr ./bin \
  && rm -rf s6-overlay-${ARCH}.tar.gz \
  && mkdir -p ${GUACAMOLE_HOME} \
  ${GUACAMOLE_HOME}/lib \
  ${GUACAMOLE_HOME}/extensions

WORKDIR ${GUACAMOLE_HOME}

RUN \
  apt-get update && \
  # Needed to import the LLVM repo key and handle the HTTPS cert
  apt-get install gnupg2 ca-certificates -y

COPY postgresql.list /etc/apt/sources.list.d

# Install dependencies
RUN \
  apt-key adv --fetch-keys https://www.postgresql.org/media/keys/ACCC4CF8.asc && \
  apt-get update && apt-get install -y \
  libcairo2-dev libjpeg62-turbo-dev libpng-dev \
  libossp-uuid-dev libavcodec-dev libavutil-dev \
  libswscale-dev freerdp2-dev libfreerdp-client2-2 libpango1.0-dev \
  libssh2-1-dev libtelnet-dev libvncserver-dev \
  libpulse-dev libssl-dev libvorbis-dev libwebp-dev libwebsockets-dev \
  ghostscript postgresql-${PG_MAJOR} build-essential --no-install-recommends\
  && rm -rf /var/lib/apt/lists/*

# Link FreeRDP to where guac expects it to be
RUN [ "$ARCH" = "armhf" ] && ln -s /usr/local/lib/freerdp /usr/lib/arm-linux-gnueabihf/freerdp || exit 0
RUN [ "$ARCH" = "amd64" ] && ln -s /usr/local/lib/freerdp /usr/lib/x86_64-linux-gnu/freerdp || exit 0

# Install guacamole-server
RUN curl -SLO "http://apache.org/dyn/closer.cgi?action=download&filename=guacamole/${GUAC_VER}/source/guacamole-server-${GUAC_VER}.tar.gz" \
  && tar -xzf guacamole-server-${GUAC_VER}.tar.gz \
  && cd guacamole-server-${GUAC_VER} \
  && CFLAGS="-DFREERDP_SVC_CORE_FREES_WSTREAM=1" ./configure --enable-allow-freerdp-snapshots\
  && CFLAGS="-DFREERDP_SVC_CORE_FREES_WSTREAM=1" make -j$(getconf _NPROCESSORS_ONLN) \
  && make install \
  && cd .. \
  && rm -rf guacamole-server-${GUAC_VER}.tar.gz guacamole-server-${GUAC_VER} \
  && ldconfig

# Install guacamole-client and postgres auth adapter
RUN set -x \
  && rm -rf ${CATALINA_HOME}/webapps/ROOT \
  && curl -SLo ${CATALINA_HOME}/webapps/ROOT.war "http://apache.org/dyn/closer.cgi?action=download&filename=guacamole/${GUAC_VER}/binary/guacamole-${GUAC_VER}.war" \
  && curl -SLo ${GUACAMOLE_HOME}/lib/postgresql-${JDBC_VER}.jar "https://jdbc.postgresql.org/download/postgresql-${JDBC_VER}.jar" \
  && curl -SLO "http://apache.org/dyn/closer.cgi?action=download&filename=guacamole/${GUAC_VER}/binary/guacamole-auth-jdbc-${GUAC_VER}.tar.gz" \
  && tar -xzf guacamole-auth-jdbc-${GUAC_VER}.tar.gz \
  && cp -R guacamole-auth-jdbc-${GUAC_VER}/postgresql/guacamole-auth-jdbc-postgresql-${GUAC_VER}.jar ${GUACAMOLE_HOME}/extensions/ \
  && cp -R guacamole-auth-jdbc-${GUAC_VER}/postgresql/schema ${GUACAMOLE_HOME}/ \
  && rm -rf guacamole-auth-jdbc-${GUAC_VER} guacamole-auth-jdbc-${GUAC_VER}.tar.gz

# Add optional extensions
RUN set -xe \
  && mkdir ${GUACAMOLE_HOME}/extensions-available \
  && for i in auth-ldap auth-duo auth-header auth-cas auth-openid auth-quickconnect auth-totp; do \
  echo "http://apache.org/dyn/closer.cgi?action=download&filename=guacamole/${GUAC_VER}/binary/guacamole-${i}-${GUAC_VER}.tar.gz" \
  && curl -SLO "http://apache.org/dyn/closer.cgi?action=download&filename=guacamole/${GUAC_VER}/binary/guacamole-${i}-${GUAC_VER}.tar.gz" \
  && tar -xzf guacamole-${i}-${GUAC_VER}.tar.gz \
  && cp guacamole-${i}-${GUAC_VER}/guacamole-${i}-${GUAC_VER}.jar ${GUACAMOLE_HOME}/extensions-available/ \
  && rm -rf guacamole-${i}-${GUAC_VER} guacamole-${i}-${GUAC_VER}.tar.gz \
  ;done

ENV PATH=/usr/lib/postgresql/${PG_MAJOR}/bin:$PATH
ENV GUACAMOLE_HOME=/config/guacamole

WORKDIR /config

COPY root /

EXPOSE 8080

ENTRYPOINT [ "/init" ]
