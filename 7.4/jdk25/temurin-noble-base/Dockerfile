#
# NOTE: THIS DOCKERFILE IS GENERATED VIA "update.sh"
#
# PLEASE DO NOT EDIT IT DIRECTLY.
#

# "Base" edition — same runtime as the full image, but with all content that
# downstream images are expected to provide themselves removed: factory config
# XMLs, welcome page, welcome-adapter resources, and PDF documentation.
# The sed step that rewrites conf/lightstreamer_log_conf.xml is dropped too,
# since the file it targets is stripped a moment later.

FROM buildpack-deps:bookworm-curl AS builder

# Set args to identify the right Lightstreamer version to download and the right public key to verify the signature of the downloaded package
ARG LIGHTSTREAMER_URL_DOWNLOAD=https://lightstreamer.com/distros/ls-server/7.4.8/Lightstreamer-7.4.8.tar.gz
ARG FINGERPRINT=9B90BFD14309C7DA5EF58D7D4A8C08966F29B4D2

WORKDIR /lightstreamer

RUN set -ex; \
# Download the package from the Lightstreamer site
        curl -fSL -o Lightstreamer.tar.gz ${LIGHTSTREAMER_URL_DOWNLOAD} \
        && curl -fSL -o Lightstreamer.tar.gz.asc ${LIGHTSTREAMER_URL_DOWNLOAD}.asc \
# Import Lighstreamer's public key and verify the signature of the downloaded package
        && GNUPGHOME="$(mktemp -d)" \
        && export GNUPGHOME \
        && gpg --batch --keyserver hkps://keys.openpgp.org --recv-keys "${FINGERPRINT}" \
        && gpg --batch --verify Lightstreamer.tar.gz.asc Lightstreamer.tar.gz \
# Unpack
        && tar -xf Lightstreamer.tar.gz --strip-components=1 \
# Strip content that downstream images are expected to provide themselves.
        && rm -rf docs pages adapters/welcome_res \
        && rm -f conf/*.xml \
        && rm -rf bin/unix-like/install \
        && rm -rf bin/windows \
# Finally, remove no longer needed files
        && rm Lightstreamer.tar.gz Lightstreamer.tar.gz.asc \
        && gpgconf --kill all \
	&& rm -rf "$GNUPGHOME"

# Set the base image for the final image
FROM eclipse-temurin:25-jdk-noble
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

# Downstream images MUST provide their own conf/*.xml (and any adapters they
# need) before the container can start.
CMD ["./LS.sh", "run"]
