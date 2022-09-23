# Set the base image
FROM eclipse-temurin:11-jdk

LABEL maintainer="Lightstreamer Server Development Team <support@lightstreamer.com>"

# Add gpg, which is missing in the eclipse-temurin image
RUN apt-get -y update \
        && apt-get -y install gnupg \
        && rm -rf /var/lib/apt/lists/*

# Import Lighstreamer's public key
RUN gpg --batch --keyserver hkp://keyserver.ubuntu.com --recv-keys 9B90BFD14309C7DA5EF58D7D4A8C08966F29B4D2

# Set environment variables to identify the right Lightstreamer version and edition
ENV LIGHTSTREAMER_VERSION 7.2.2
ENV LIGHTSTREAMER_URL_DOWNLOAD https://lightstreamer.com/distr/ls-server/${LIGHTSTREAMER_VERSION}/Lightstreamer-${LIGHTSTREAMER_VERSION}.tar.gz

# Download the package from the Lightstreamer site, verify the signature, and unpack
RUN set -ex; \
        mkdir /lightstreamer && cd /lightstreamer \
        && curl -fSL -o Lightstreamer.tar.gz ${LIGHTSTREAMER_URL_DOWNLOAD} \
        && curl -fSL -o Lightstreamer.tar.gz.asc ${LIGHTSTREAMER_URL_DOWNLOAD}.asc \
        && gpg --batch --verify Lightstreamer.tar.gz.asc Lightstreamer.tar.gz \
        && tar -xvf Lightstreamer.tar.gz --strip-components=1 \
# Adjust the logging configuration in order to log only on standard output
        && sed -i -e 's/<appender-ref ref="LSDailyRolling" \/>/<appender-ref ref="LSConsole" \/>/' \
                  -e '/<logger name="LightstreamerLogger.init/,+2s/<appender-ref ref="LSConsole" \/>/<!-- <appender-ref ref="LSConsole" \/> -->/' \
                  -e '/<logger name="LightstreamerLogger.license/,+2s/<appender-ref ref="LSConsole" \/>/<!-- <appender-ref ref="LSConsole" \/> -->/' \
                  -e '/<logger name="LightstreamerProxyAdapters/,+2s/<appender-ref ref="LSConsole" \/>/<!-- <appender-ref ref="LSConsole" \/> -->/' \
                  conf/lightstreamer_log_conf.xml \
# Add new user and group
        && groupadd -r -g 10000 lightstreamer \
        && useradd --no-log-init -r -g lightstreamer -u 10000 lightstreamer \
# Change ownership of the lightstreamer folder
        && chown -R lightstreamer:lightstreamer ../lightstreamer \
# Finally, remove no longer needed files
        && rm Lightstreamer.tar.gz Lightstreamer.tar.gz.asc

USER lightstreamer

# Export TCP port 8080
EXPOSE 8080

# Set the final working dir
WORKDIR /lightstreamer/bin/unix-like

# Start the server
CMD ["./LS.sh", "run"]