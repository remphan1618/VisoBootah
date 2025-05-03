# Stage 1: Base image for development and dependencies
FROM nvidia/cuda:12.4.1-cudnn-runtime-ubuntu22.04 AS base

ENV REFRESHED_AT=2025-05-03 \
    DISPLAY=:1 \
    VNC_PORT=5901 \
    NO_VNC_PORT=6901 \
    HOME=/workspace \
    TERM=xterm \
    STARTUPDIR=/dockerstartup \
    INST_SCRIPTS=/workspace/install \
    NO_VNC_HOME=/workspace/noVNC \
    DEBIAN_FRONTEND=noninteractive \
    VNC_COL_DEPTH=24 \
    VNC_PW=vncpassword \
    VNC_VIEW_ONLY=false \
    TZ=Asia/Seoul

LABEL io.k8s.description="Headless VNC Container with Xfce window manager, Firefox, and Chromium" \
      io.k8s.display-name="Headless VNC Container based on Debian" \
      io.openshift.expose-services="6901:http,5901:xvnc" \
      io.openshift.tags="vnc, debian, xfce" \
      io.openshift.non-scalable=true

WORKDIR $HOME

# Install system dependencies, then clean up
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
      wget git build-essential \
      software-properties-common apt-transport-https ca-certificates \
      unzip ffmpeg jq tzdata python3 python3-pip && \
    apt-get clean && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /usr/share/doc /usr/share/man /usr/share/locale/*

# Install Miniconda & clean up
RUN wget -q https://repo.anaconda.com/miniconda/Miniconda3-latest-Linux-x86_64.sh -O miniconda.sh && \
    bash miniconda.sh -b -p /opt/conda && \
    rm miniconda.sh && \
    /opt/conda/bin/conda clean -afy && \
    rm -rf /root/.conda ~/.cache ~/.npm /root/.cache

ENV PATH=/opt/conda/bin:$PATH

# Copy installation scripts
COPY ./src/common/install/ $INST_SCRIPTS/
COPY ./src/debian/install/ $INST_SCRIPTS/
COPY ./src/common/xfce/ $HOME/
COPY ./src/common/scripts/ $STARTUPDIR/
RUN chmod +x $INST_SCRIPTS/*.sh

# Install software and dependencies, then clean up
RUN $INST_SCRIPTS/tools.sh && \
    $INST_SCRIPTS/install_custom_fonts.sh && \
    $INST_SCRIPTS/tigervnc.sh && \
    $INST_SCRIPTS/no_vnc_1.5.0.sh && \
    $INST_SCRIPTS/firefox.sh && \
    $INST_SCRIPTS/xfce_ui.sh && \
    $INST_SCRIPTS/libnss_wrapper.sh && \
    $INST_SCRIPTS/set_user_permission.sh $STARTUPDIR $HOME && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* /usr/share/doc /usr/share/man /usr/share/locale/*

# Stage 2: Build environment for Python and VisoMaster
FROM base AS build

# Set up conda, mamba, and clean up
RUN conda install -n base -c conda-forge mamba -y && \
    mamba create -n VisoMaster python=3.10.13 -y && \
    mamba clean --all -y && \
    echo "source activate VisoMaster" >> ~/.bashrc && \
    rm -rf /opt/conda/pkgs/* ~/.cache ~/.npm /root/.cache

ENV CONDA_DEFAULT_ENV=VisoMaster
ENV PATH=/opt/conda/envs/$CONDA_DEFAULT_ENV/bin:$PATH

# Install Python packages and CUDA dependencies, then clean up
RUN mamba install -n VisoMaster scikit-image -y && \
    mamba install -n VisoMaster -c nvidia/label/cuda-12.4.1 cuda-runtime cudnn -y && \
    mamba clean --all -y && \
    rm -rf /opt/conda/pkgs/* ~/.cache ~/.npm /root/.cache

# Clone VisoMaster (shallow clone to save space)
WORKDIR /workspace
RUN git clone --depth 1 https://github.com/remphan1618/VisoMaster.git VisoMaster && \
    cd VisoMaster && \
    git config --global --add safe.directory /workspace/VisoMaster

WORKDIR /workspace/VisoMaster

# Failsafe: Download requirements.txt if missing
RUN if [ ! -f requirements.txt ]; then \
      echo "requirements.txt not found, downloading from GitHub..."; \
      wget https://raw.githubusercontent.com/remphan1618/VisoMaster/main/requirements.txt; \
    fi

RUN pip install --no-cache-dir -r requirements.txt && \
    pip cache purge && \
    rm -rf ~/.cache ~/.npm /root/.cache

# Create minimal placeholder structure for models
RUN mkdir -p model_assets && \
    echo "Models will be downloaded on first run.\nTo manually download models, run: python download_models.py" > model_assets/README.txt

# Create a dummy notebook file in case it doesn't exist
RUN touch /workspace/VisoMaster/VisoMaster_Setup_Fix_Simplified.ipynb

# Stage 3: Final runtime image, clean up at every step
FROM base AS runtime

COPY --from=build /workspace /workspace
COPY --from=build /opt/conda /opt/conda

WORKDIR /workspace/VisoMaster

RUN mkdir -p /workspace/VisoMaster/logs && \
    chmod -R 777 /workspace && \
    rm -rf /var/lib/apt/lists/* /tmp/* /var/tmp/* ~/.cache ~/.npm /root/.cache /opt/conda/pkgs/* /usr/share/doc /usr/share/man /usr/share/locale/*

# Add a script to download models on first run
RUN echo '#!/bin/bash\ncd /workspace/VisoMaster\nif [ ! -f model_assets/models_downloaded ]; then\n  echo "Downloading models on first run..."\n  python download_models.py && touch model_assets/models_downloaded\nfi\n/dockerstartup/vnc_startup.sh "$@"' > /workspace/VisoMaster/run.sh && chmod +x /workspace/VisoMaster/run.sh

COPY ./src/vnc_startup_jupyterlab_filebrowser.sh /dockerstartup/vnc_startup.sh
RUN chmod 765 /dockerstartup/vnc_startup.sh

ENV VNC_RESOLUTION=1280x1024

EXPOSE 5901 6901 8080 8585

ENTRYPOINT ["/workspace/VisoMaster/run.sh"]
CMD ["--wait"]
