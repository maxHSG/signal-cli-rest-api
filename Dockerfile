ARG SIGNAL_CLI_VERSION=0.7.2
ARG ZKGROUP_VERSION=0.7.0

ARG SWAG_VERSION=1.6.7

# fetch the vendor with the builder platform to avoid qemu issues
FROM --platform=$BUILDPLATFORM rust:1-buster AS rust-sources-downloader

ARG ZKGROUP_VERSION

RUN cd /tmp/ && git clone https://github.com/signalapp/zkgroup.git zkgroup-${ZKGROUP_VERSION}
RUN cd /tmp/zkgroup-${ZKGROUP_VERSION} && cargo fetch


FROM golang:1.13-buster AS buildcontainer

ARG SIGNAL_CLI_VERSION
ARG ZKGROUP_VERSION
ARG SWAG_VERSION

ENV GIN_MODE=release

RUN apt-get update \
	&& apt-get install -y --no-install-recommends wget default-jre software-properties-common git locales zip \
	&& rm -rf /var/lib/apt/lists/* 

RUN sed -i -e 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen && \
    dpkg-reconfigure --frontend=noninteractive locales && \
    update-locale LANG=en_US.UTF-8

RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y

ENV PATH="/root/.cargo/bin:${PATH}"

ENV LANG en_US.UTF-8

RUN cd /tmp/ \
	&& git clone https://github.com/swaggo/swag.git swag-${SWAG_VERSION} \	
	&& cd swag-${SWAG_VERSION} \
	&& git checkout v${SWAG_VERSION} \
	&& make \
	&& cp /tmp/swag-${SWAG_VERSION}/swag /usr/bin/swag \
	&& rm -r /tmp/swag-${SWAG_VERSION}

RUN cd /tmp/ \
	&& git clone https://github.com/AsamK/signal-cli.git signal-cli-${SIGNAL_CLI_VERSION} \
	&& cd signal-cli-${SIGNAL_CLI_VERSION} \
	&& git checkout v${SIGNAL_CLI_VERSION} \
	&& ./gradlew build \
	&& ./gradlew installDist \
	&& ln -s /tmp/signal-cli-${SIGNAL_CLI_VERSION}/build/install/signal-cli/ /tmp/signal-cli

RUN ls /tmp/signal-cli/lib/zkgroup-java-${ZKGROUP_VERSION}.jar || (echo "\n\nzkgroup jar file with version ${ZKGROUP_VERSION} not found. Maybe the version needs to be bumped in the signal-cli-rest-api Dockerfile?\n\n" && echo "Available version: \n" && ls /tmp/signal-cli/lib/zkgroup-java-* && echo "\n\n" && exit 1)

COPY --from=rust-sources-downloader /tmp/zkgroup-${ZKGROUP_VERSION} /tmp/zkgroup-${ZKGROUP_VERSION} 

RUN	cd /tmp/zkgroup-${ZKGROUP_VERSION} \
	&& make libzkgroup \
	&& ln -s /tmp/zkgroup-${ZKGROUP_VERSION} /tmp/zkgroup

RUN cd /tmp/signal-cli \
	&& cd /tmp/zkgroup-${ZKGROUP_VERSION}/target/release/ \
	&& zip -u /tmp/signal-cli/lib/zkgroup-java-*.jar libzkgroup.so 

COPY src/api /tmp/signal-cli-rest-api-src/api
COPY src/main.go /tmp/signal-cli-rest-api-src/
COPY src/go.mod /tmp/signal-cli-rest-api-src/
COPY src/go.sum /tmp/signal-cli-rest-api-src/

RUN cd /tmp/signal-cli-rest-api-src && swag init && go build

# Start a fresh container for release container
FROM adoptopenjdk:11-jdk-hotspot-bionic

RUN apt-get update \
	&& apt-get install -y --no-install-recommends setpriv \
	&& rm -rf /var/lib/apt/lists/* 

COPY --from=buildcontainer /tmp/signal-cli-rest-api-src/signal-cli-rest-api /usr/bin/signal-cli-rest-api
COPY --from=buildcontainer /tmp/signal-cli /opt/signal-cli
COPY entrypoint.sh /entrypoint.sh

RUN groupadd -g 1000 signal-api \
	&& useradd --no-log-init -M -d /home -s /bin/bash -u 1000 -g 1000 signal-api \
	&& ln -s /opt/signal-cli/bin/signal-cli /usr/bin/signal-cli \
	&& mkdir -p /signal-cli-config/ \
	&& mkdir -p /home/.local/share/signal-cli

EXPOSE 8080

ENTRYPOINT ["/entrypoint.sh"]
