FROM --platform=$TARGETOS/$TARGETARCH ghcr.io/steamcmd/steamcmd:debian-13 AS steamcmd

FROM --platform=$TARGETOS/$TARGETARCH debian:trixie-slim

USER root
ARG DOTNET_RUNTIME_VERSION=10.0.14
ARG STEAMCMD_BUILD_ID=7

RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    ca-certificates curl tar git iproute2 tzdata libicu76 libvulkan1 mesa-vulkan-drivers \
    libc6-i386 lib32gcc-s1 lib32stdc++6 \
    libx11-6 libxext6 libxrender1 libxrandr2 libxi6 libxcursor1 libxfixes3 \
    libfontconfig1 libfreetype6 libice6 libsm6 \
    libwayland-client0 libwayland-cursor0 libwayland-egl1 libxkbcommon0 \
    libpulse0 libasound2t64 xvfb \
 && mkdir -p /usr/share/dotnet /opt/steamcmd \
 && curl -fsSL "https://builds.dotnet.microsoft.com/dotnet/Runtime/${DOTNET_RUNTIME_VERSION}/dotnet-runtime-${DOTNET_RUNTIME_VERSION}-linux-x64.tar.gz" -o /tmp/dotnet-runtime.tar.gz \
 && echo "634326028645f38731c8c4e71a68356e4ca0d6b6607139a234ab760687f742063edaf33a1f20dda615742d2dc8300ca2ff857619d51fbb38090383b71334af89  /tmp/dotnet-runtime.tar.gz" | sha512sum -c - \
 && tar -xzf /tmp/dotnet-runtime.tar.gz -C /usr/share/dotnet \
 && rm -f /tmp/dotnet-runtime.tar.gz \
 && rm -rf /var/lib/apt/lists/* \
 && useradd -m -d /home/container container \
 && chown -R container:container /opt/steamcmd

COPY --from=steamcmd --chown=container:container /root/.local/share/Steam/steamcmd/ /opt/steamcmd/
RUN test -x /opt/steamcmd/linux32/steamcmd \
 && test -x /opt/steamcmd/steamcmd.sh \
 && test -f /opt/steamcmd/linux64/steamclient.so \
 && mkdir -p /tmp/steamcmd-build-home \
 && STEAM_PLATFORM=linux64 HOME=/tmp/steamcmd-build-home /opt/steamcmd/steamcmd.sh +quit \
 && mkdir -p /opt/steamcmd-home \
 && cp -a /tmp/steamcmd-build-home/Steam /opt/steamcmd-home/ \
 && chown -R container:container /opt/steamcmd-home \
 && rm -rf /tmp/steamcmd-build-home

ENV DOTNET_ROOT=/usr/share/dotnet \
    PATH="/usr/share/dotnet:${PATH}" \
    STEAMCMD=/opt/steamcmd/steamcmd.sh \
    STEAMCMD_BUILD_ID=${STEAMCMD_BUILD_ID} \
    USER=container \
    HOME=/home/container
WORKDIR /home/container
USER container

COPY --chmod=755 ./entrypoint.sh /entrypoint.sh
CMD ["/bin/bash", "/entrypoint.sh"]
