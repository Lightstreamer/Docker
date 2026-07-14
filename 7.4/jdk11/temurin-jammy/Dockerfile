# Set the base image 
FROM buildpack-deps:bookworm-curl AS builder

# Set args to identify the right Lightstreamer version to download and the right public key to verify the signature of the downloaded package
ARG LIGHTSTREAMER_URL_DOWNLOAD=https://lightstreamer.com/distros/ls-server/7.4.8/Lightstreamer-7.4.8.tar.gz
ARG FINGERPRINT=9B90BFD14309C7DA5EF58D7D4A8C08966F29B4D2

RUN set -ex; \
# Download the package from the Lightstreamer site
        mkdir /lightstreamer && cd /lightstreamer \
        && curl -fSL -o Lightstreamer.tar.gz ${LIGHTSTREAMER_URL_DOWNLOAD} \
        && curl -fSL -o Lightstreamer.tar.gz.asc ${LIGHTSTREAMER_URL_DOWNLOAD}.asc \
# Import Lighstreamer's public key and verify the signature of the downloaded package
        && export GNUPGHOME="$(mktemp -d)" \
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

# Set the base image for the final image
FROM eclipse-temurin:11-jdk-jammy
LABEL maintainer="Lightstreamer Server Development Team <support@lightstreamer.com>"
ENV LIGHTSTREAMER_VERSION=7.4.8

RUN groupadd -g 10000 lightstreamer \
        && useradd --no-log-init -M -s /usr/sbin/nologin -g lightstreamer -u 10000 lightstreamer

COPY --from=builder --chown=lightstreamer:lightstreamer /lightstreamer /lightstreamer

USER 10000:10000

# Export TCP port 8080
EXPOSE 8080

# Set the final working dir
WORKDIR /lightstreamer/bin/unix-like

# Start the server
CMD ["./LS.sh", "run"]