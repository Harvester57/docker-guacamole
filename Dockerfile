# Multi-stage build for Apache Guacamole
# Cf. https://hub.docker.com/_/debian
ARG BUILDKIT_SBOM_SCAN_STAGE=true
ARG GUAC_VER=1.6.0

# -------------------------------------------------------------
# Stage 1: Build guacamole-server
# -------------------------------------------------------------
FROM debian:bookworm-20261005-slim@sha256:a4672c0cb26fbdde88e38fa2dfb6c681942306680e41e4378b28770b6e79ee91 AS builder

ARG GUAC_VER
ARG DEBIAN_FRONTEND=noninteractive

WORKDIR /app/guacamole

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    build-essential \
    libcairo2-dev \
    libjpeg62-turbo-dev \
    libpng-dev \
    libossp-uuid-dev \
    libavcodec-dev \
    libavutil-dev \
    libavformat-dev \
    libswscale-dev \
    freerdp2-dev \
    libfreerdp-client2-2 \
    libpango1.0-dev \
    libssh2-1-dev \
    libvncserver-dev \
    libssl-dev \
    libvorbis-dev \
    libwebp-dev \
    libwebsockets-dev \
    ghostscript && \
    rm -rf /var/lib/apt/lists/*

RUN curl -sSL "https://dlcdn.apache.org/guacamole/${GUAC_VER}/source/guacamole-server-${GUAC_VER}.tar.gz" | tar -xz

WORKDIR /app/guacamole/guacamole-server-${GUAC_VER}

RUN export CFLAGS="-O3 -pipe -fstack-protector-strong -D_FORTIFY_SOURCE=2 -fstack-clash-protection -fPIE -pie" && \
    export LDFLAGS="-Wl,-z,relro -Wl,-z,now -Wl,--as-needed" && \
    ./configure \
    --prefix=/usr/local \
    --disable-guacenc \
    --disable-guaclog \
    --disable-kubernetes \
    --with-rdp \
    --with-vnc \
    --with-ssh \
    --without-telnet && \
    make -j$(nproc) && \
    make install DESTDIR=/install

# -------------------------------------------------------------
# Stage 2: Runtime image (Tomcat 9 on Debian Bookworm)
# -------------------------------------------------------------
FROM tomcat:9.0-jre21-temurin-noble@sha256:f5493380c0b71f044aa4d0362dc119f350c62dc157f753be6dcf1e3099520d7a AS tomcat

# Cf. https://hub.docker.com/_/debian
FROM debian:bookworm-20261005-slim@sha256:a4672c0cb26fbdde88e38fa2dfb6c681942306680e41e4378b28770b6e79ee91

LABEL org.opencontainers.image.authors="Florian Stosse <florian.stosse@gmail.com>"
LABEL org.opencontainers.image.description="Apache Guacamole environment"
LABEL org.opencontainers.image.licenses="Apache-2.0"

ARG ARCH=amd64
ARG S6_ARCH=x86_64
ARG GUAC_VER=1.6.0
ARG GUACAMOLE_HOME=/app/guacamole
ARG PG_MAJOR=15
# https://jdbc.postgresql.org/download/
ARG JDBC_VER=42.7.13
# https://github.com/just-containers/s6-overlay/releases
ARG S6_OVERLAY_VERSION=3.2.3.2
ARG DEBIAN_FRONTEND=noninteractive

ENV GUAC_VER=${GUAC_VER} \
    GUACAMOLE_HOME=/config/guacamole \
    PG_MAJOR=${PG_MAJOR} \
    PGDATA=/config/postgres \
    POSTGRES_USER=guacamole \
    POSTGRES_DB=guacamole_db \
    JAVA_HOME=/opt/java/openjdk \
    CATALINA_HOME=/usr/local/tomcat \
    PATH="/usr/local/tomcat/bin:/opt/java/openjdk/bin:/usr/lib/postgresql/${PG_MAJOR}/bin:$PATH"

COPY --from=tomcat /opt/java/openjdk /opt/java/openjdk
COPY --from=tomcat /usr/local/tomcat /usr/local/tomcat

WORKDIR ${GUACAMOLE_HOME}

# Install runtime packages (PostgreSQL 15, FreeRDP runtime libs, utilities)
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    curl \
    ca-certificates \
    xz-utils \
    postgresql-${PG_MAJOR} \
    postgresql-contrib-${PG_MAJOR} \
    libcairo2 \
    libjpeg62-turbo \
    libpng16-16 \
    libossp-uuid16 \
    libavcodec59 \
    libavutil57 \
    libavformat59 \
    libswscale6 \
    libfreerdp2-2 \
    libfreerdp-client2-2 \
    libfreerdp-server2-2 \
    libfreerdp-shadow2-2 \
    libfreerdp-shadow-subsystem2-2 \
    libpango-1.0-0 \
    libssh2-1 \
    libvncserver1 \
    libvncclient1 \
    libssl3 \
    libvorbis0a \
    libvorbisenc2 \
    libwebp7 \
    libwebsockets17 \
    ghostscript && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/*

# Install s6-overlay v3 with legacy symlinks for cont-init / services support
RUN curl -sSL "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-noarch.tar.xz" | tar -Jxpf - -C / && \
    curl -sSL "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-${S6_ARCH}.tar.xz" | tar -Jxpf - -C / && \
    curl -sSL "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-symlinks-noarch.tar.xz" | tar -Jxpf - -C / && \
    curl -sSL "https://github.com/just-containers/s6-overlay/releases/download/v${S6_OVERLAY_VERSION}/s6-overlay-symlinks-arch.tar.xz" | tar -Jxpf - -C / && \
    mkdir -p /app/guacamole/lib /app/guacamole/extensions /app/guacamole/extensions-available /config

# Copy compiled guacamole-server from builder stage
COPY --from=builder /install/usr/local /usr/local
RUN ldconfig

# FreeRDP plugins directory link
RUN [ "$ARCH" = "amd64" ] && ln -s /usr/local/lib/freerdp2 /usr/lib/x86_64-linux-gnu/freerdp2 || exit 0

# Install guacamole-client (WAR) and PostgreSQL auth extension
RUN set -x && \
    rm -rf ${CATALINA_HOME}/webapps/ROOT && \
    curl -sSL -o ${CATALINA_HOME}/webapps/ROOT.war "https://dlcdn.apache.org/guacamole/${GUAC_VER}/binary/guacamole-${GUAC_VER}.war" && \
    curl -sSL -o /app/guacamole/lib/postgresql-${JDBC_VER}.jar "https://jdbc.postgresql.org/download/postgresql-${JDBC_VER}.jar" && \
    curl -sSL "https://dlcdn.apache.org/guacamole/${GUAC_VER}/binary/guacamole-auth-jdbc-${GUAC_VER}.tar.gz" | tar -xz -C /tmp && \
    cp /tmp/guacamole-auth-jdbc-${GUAC_VER}/postgresql/guacamole-auth-jdbc-postgresql-${GUAC_VER}.jar /app/guacamole/extensions/ && \
    cp -R /tmp/guacamole-auth-jdbc-${GUAC_VER}/postgresql/schema /app/guacamole/ && \
    rm -rf /tmp/guacamole-auth-jdbc-${GUAC_VER}*

# Install optional extensions (auth-ldap, auth-totp, auth-quickconnect, auth-duo, auth-header, and SSO openid/cas)
RUN for ext in auth-ldap auth-totp auth-quickconnect auth-duo auth-header; do \
    curl -sSL "https://dlcdn.apache.org/guacamole/${GUAC_VER}/binary/guacamole-${ext}-${GUAC_VER}.tar.gz" | tar -xz -C /tmp && \
    cp /tmp/guacamole-${ext}-${GUAC_VER}/guacamole-${ext}-${GUAC_VER}.jar /app/guacamole/extensions-available/ && \
    rm -rf /tmp/guacamole-${ext}-${GUAC_VER}*; \
    done && \
    curl -sSL "https://dlcdn.apache.org/guacamole/${GUAC_VER}/binary/guacamole-auth-sso-${GUAC_VER}.tar.gz" | tar -xz -C /tmp && \
    cp /tmp/guacamole-auth-sso-${GUAC_VER}/openid/guacamole-auth-sso-openid-${GUAC_VER}.jar /app/guacamole/extensions-available/guacamole-auth-openid-${GUAC_VER}.jar && \
    cp /tmp/guacamole-auth-sso-${GUAC_VER}/cas/guacamole-auth-sso-cas-${GUAC_VER}.jar /app/guacamole/extensions-available/guacamole-auth-cas-${GUAC_VER}.jar && \
    rm -rf /tmp/guacamole-auth-sso-${GUAC_VER}*

WORKDIR /config

COPY root /
RUN find /etc/cont-init.d /etc/services.d -type f -exec sed -i 's/\r$//' {} + && \
    chmod +x /etc/cont-init.d/* /etc/services.d/*/run

EXPOSE 8080

ENTRYPOINT [ "/init" ]
