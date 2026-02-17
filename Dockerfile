FROM ubuntu:latest

ENV DEBIAN_FRONTEND=noninteractive

RUN apt-get update && apt-get install -y \
    xorg \
    x11-apps \
    x11-utils \
    x11-xserver-utils \
    dbus-x11 \
    libgl1 \
    libgl1-mesa-dri \
    libglib2.0-0 \
    libgtk-3-0 \
    libpulse0 \
    libasound2t64 \
    libcanberra-gtk3-module \
    libxcomposite1 \
    libxcursor1 \
    libxdamage1 \
    libxfixes3 \
    libxi6 \
    libxrandr2 \
    libxrender1 \
    libxtst6 \
    libxss1 \
    libxkbcommon0 \
    libxkbcommon-x11-0 \
    libxcb-icccm4 \
    libxcb-image0 \
    libxcb-keysyms1 \
    libxcb-render-util0 \
    libxcb-xinerama0 \
    libxcb-xkb1 \
    libatk1.0-0 \
    libatk-bridge2.0-0 \
    libpango-1.0-0 \
    libcairo2 \
    libgdk-pixbuf-2.0-0 \
    libdrm2 \
    libgbm1 \
    mesa-vulkan-drivers \
    fonts-dejavu-core \
    fonts-liberation \
    fonts-noto-color-emoji \
    fonts-noto-cjk \
    fonts-wqy-zenhei \
    fonts-wqy-microhei \
    locales \
    sudo \
    && rm -rf /var/lib/apt/lists/*

# Install Firefox from Mozilla PPA (the Ubuntu snap package doesn't work in containers)
RUN apt-get update && apt-get install -y software-properties-common \
    && add-apt-repository -y ppa:mozillateam/ppa \
    && printf 'Package: *\nPin: release o=LP-PPA-mozillateam\nPin-Priority: 1001\n' > /etc/apt/preferences.d/mozilla-firefox \
    && apt-get update && apt-get install -y firefox \
    && rm -rf /var/lib/apt/lists/*

# Install Google Chrome
RUN apt-get update && apt-get install -y wget gnupg \
    && wget -q -O - https://dl.google.com/linux/linux_signing_key.pub | gpg --dearmor -o /usr/share/keyrings/google-chrome.gpg \
    && echo "deb [arch=amd64 signed-by=/usr/share/keyrings/google-chrome.gpg] http://dl.google.com/linux/chrome/deb/ stable main" > /etc/apt/sources.list.d/google-chrome.list \
    && apt-get update && apt-get install -y google-chrome-stable \
    && rm -rf /var/lib/apt/lists/*

# Persistent mode: VNC server and lightweight window manager
RUN apt-get update && apt-get install -y \
    tigervnc-standalone-server \
    tigervnc-common \
    openbox \
    obconf \
    xterm \
    && rm -rf /var/lib/apt/lists/*

RUN locale-gen en_US.UTF-8 && locale-gen zh_CN.UTF-8
ENV LANG=en_US.UTF-8
ENV LANGUAGE=en_US:en
ENV LC_ALL=en_US.UTF-8

# Install packages from external_app folder
COPY external_app/ /tmp/external_app/
RUN apt-get update \
    && apt-get install -y /tmp/external_app/*.deb \
    && rm -rf /tmp/external_app /var/lib/apt/lists/*

ARG USERNAME=user
ARG USER_UID=1000
ARG USER_GID=1000

RUN userdel -r ubuntu 2>/dev/null || true \
    && groupadd --force --gid ${USER_GID} ${USERNAME} \
    && useradd --uid ${USER_UID} --gid ${USER_GID} -m ${USERNAME} \
    && echo "${USERNAME} ALL=(ALL) NOPASSWD:ALL" >> /etc/sudoers

COPY start-app.sh /usr/local/bin/start-app.sh
RUN chmod +x /usr/local/bin/start-app.sh

COPY start-persistent.sh /usr/local/bin/start-persistent.sh
RUN chmod +x /usr/local/bin/start-persistent.sh

USER ${USERNAME}
WORKDIR /home/${USERNAME}

ENTRYPOINT ["/usr/local/bin/start-app.sh"]
