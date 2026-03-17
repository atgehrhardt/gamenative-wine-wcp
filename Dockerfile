FROM ubuntu:24.04

ENV DEBIAN_FRONTEND=noninteractive
ARG ANDROID_NDK_VERSION=r27d
ARG LLVM_MINGW_VERSION=20251007

RUN apt-get update && apt-get install -y \
    bison \
    build-essential \
    ca-certificates \
    file \
    flex \
    git \
    lld \
    llvm \
    make \
    perl \
    pkg-config \
    curl \
    python3 \
    unzip \
    tar \
    xz-utils \
    zstd && \
    rm -rf /var/lib/apt/lists/*

RUN curl -fsSL -o /tmp/android-ndk.zip \
      "https://dl.google.com/android/repository/android-ndk-${ANDROID_NDK_VERSION}-linux.zip" && \
    unzip -q /tmp/android-ndk.zip -d /opt && \
    ln -s "/opt/android-ndk-${ANDROID_NDK_VERSION}" /opt/android-ndk && \
    rm -f /tmp/android-ndk.zip

RUN curl -fsSL "https://github.com/mstorsjo/llvm-mingw/releases/download/${LLVM_MINGW_VERSION}/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-x86_64.tar.xz" | tar -xJ -C /opt && \
    ln -s "/opt/llvm-mingw-${LLVM_MINGW_VERSION}-ucrt-ubuntu-22.04-x86_64" /opt/llvm-mingw

ENV ANDROID_NDK_ROOT=/opt/android-ndk
ENV ANDROID_API=28
ENV LLVM_MINGW_ROOT=/opt/llvm-mingw

WORKDIR /workspace
