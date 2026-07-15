#
# NOTE: THIS DOCKERFILE IS GENERATED VIA "update.sh"
#
# PLEASE DO NOT EDIT IT DIRECTLY.
#

FROM buildpack-deps:bookworm-curl AS builder

ARG LIGHTSTREAMER_URL_DOWNLOAD=https://lightstreamer.com/distros/ls-server/7.4.8/Lightstreamer-7.4.8.tar.gz
ARG FINGERPRINT=9B90BFD14309C7DA5EF58D7D4A8C08966F29B4D2

WORKDIR /lightstreamer

RUN set -ex; \
# Download the package from the Lightstreamer site
        curl -fSL -o Lightstreamer.tar.gz ${LIGHTSTREAMER_URL_DOWNLOAD} \
        && curl -fSL -o Lightstreamer.tar.gz.asc ${LIGHTSTREAMER_URL_DOWNLOAD}.asc \
# Import Lightstreamer's public key and verify the signature of the downloaded package
        && GNUPGHOME="$(mktemp -d)" \
        && export GNUPGHOME \
        && gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys "${FINGERPRINT}" \
        && gpg --batch --verify Lightstreamer.tar.gz.asc Lightstreamer.tar.gz \
# Unpack
        && tar -xf Lightstreamer.tar.gz --strip-components=1 \
# Adjust the logging configuration in order to log only on standard output
        && sed -i -e 's/<appender-ref ref="LSDailyRolling" \/>/<appender-ref ref="LSConsole" \/>/' \
                  -e '/<logger name="LightstreamerLogger.init/,+2s/<appender-ref ref="LSConsole" \/>/<!-- <appender-ref ref="LSConsole" \/> -->/' \
                  -e '/<logger name="LightstreamerLogger.license/,+2s/<appender-ref ref="LSConsole" \/>/<!-- <appender-ref ref="LSConsole" \/> -->/' \
                  -e '/<logger name="LightstreamerProxyAdapters/,+2s/<appender-ref ref="LSConsole" \/>/<!-- <appender-ref ref="LSConsole" \/> -->/' \
                  conf/lightstreamer_log_conf.xml \
# Finally, remove no longer needed files
        && rm Lightstreamer.tar.gz Lightstreamer.tar.gz.asc \
        && gpgconf --kill all \
        && rm -rf "$GNUPGHOME"

FROM eclipse-temurin:17-jdk-noble
LABEL maintainer="Lightstreamer Server Development Team <support@lightstreamer.com>"
ENV LIGHTSTREAMER_VERSION=7.4.8

RUN groupadd -g 10000 lightstreamer \
        && useradd --no-log-init -M -s /usr/sbin/nologin -g lightstreamer -u 10000 lightstreamer

# Group-owned by root (GID 0) and g=u so OpenShift's arbitrary UID (always in
# root group) can read/write. Harmless on plain Docker (user 10000 still owns
# the files and gets the same permissions via the user bits).
COPY --from=builder --chown=lightstreamer:root /lightstreamer /lightstreamer
RUN chmod -R g=u /lightstreamer

USER 10000:10000

EXPOSE 8080

WORKDIR /lightstreamer/bin/unix-like

CMD ["./LS.sh", "run"]