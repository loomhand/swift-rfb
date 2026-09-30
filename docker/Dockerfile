FROM debian:bookworm-slim
RUN apt-get update \
 && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
      xvfb x11vnc tigervnc-standalone-server ffmpeg imagemagick fonts-dejavu-core xdotool x11-utils xclip \
 && rm -rf /var/lib/apt/lists/*
COPY scene.sh /scene.sh
RUN chmod +x /scene.sh
EXPOSE 5900
ENTRYPOINT ["/scene.sh"]
