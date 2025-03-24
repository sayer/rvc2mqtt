ARG BUILD_FROM
FROM $BUILD_FROM

# 
# Docker container which pulls data off the RV-C CAN bus formats and publishes on MQTT
# Also listens for SVRSET Topics on MQTT. Executes commands to push packets onto the CAN bus
# 
#

# Set noninteractive mode
ARG DEBIAN_FRONTEND=noninteractive

# Update and install packages
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    perl \
    iproute2 \
    can-utils \
    make \
    gcc \
    build-essential \
    curl \
    libssl-dev \
    zlib1g-dev \
    ca-certificates \
    cpanminus \
    net-tools \
    kmod \
    && rm -rf /var/lib/apt/lists/*

# Install required Perl mcdules
RUN cpanm --force Net::MQTT::Simple && \
    cpanm --force Switch && \
    cpanm --force Wifi::WpaCtrl && \
    cpanm --force JSON && \
    cpanm --force JSON::Parse && \
    cpanm --force YAML::Tiny && \
    cpanm --force AnyEvent && \
    cpanm --force AnyEvent::MQTT

# Create app directory
WORKDIR /coachproxy

# Create directory structure
RUN mkdir -p /coachproxy/etc /coachproxy/rv-c /coachproxy/logs

# Copy all your original files
COPY rvc2mqtt.pl /coachproxy/rv-c/
COPY mqtt_rvc_set.pl /coachproxy/rv-c/
COPY MESSAGE.pl /coachproxy/rv-c/
COPY MESSAGE.sh /coachproxy/rv-c/
COPY process_message.sh /coachproxy/rv-c/
COPY healthcheck.pl /coachproxy/rv-c
COPY dc_dimmer.pl /coachproxy/rv-c/
COPY rvc-spec.yml /coachproxy/etc/
COPY DC_DIMMER_STATUS_3.sh /coachproxy/rv-c/
COPY THERMOSTAT_COMMAND_1_MODE.sh /coachproxy/rv-c/
COPY THERMOSTAT_COMMAND_1_TEMP.sh /coachproxy/rv-c/
COPY mqtt2rvc.pl /coachproxy/rv-c/
COPY mqtt_monitor.pl /coachproxy/rv-c/
COPY test_lights.pl /coachproxy/rv-c/
COPY mqtt2rvc_simple.pl /coachproxy/rv-c/

# Set execute permissions
RUN chmod +x /coachproxy/rv-c/*.pl /coachproxy/rv-c/*.sh && \
    chown -R root:root /coachproxy

# Create log directory with proper permissions
RUN touch /coachproxy/logs/setrvc.log.txt && \
    chmod 666 /coachproxy/logs/setrvc.log.txt

# Copy the HA required run.sh
COPY run.sh /
RUN chmod a+x /run.sh

# Environment variables
ENV PATH="/coachproxy/rv-c:${PATH}"

CMD [ "/run.sh" ]
