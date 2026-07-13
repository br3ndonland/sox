# syntax=docker/dockerfile:1
ARG ALPINE_LINUX_VERSION=3.23 UV_PYTHON
FROM ghcr.io/astral-sh/uv:python${UV_PYTHON}-alpine${ALPINE_LINUX_VERSION} AS uv
FROM alpine:${ALPINE_LINUX_VERSION}
COPY --from=uv /usr/local/ /usr/local/
ENV UV_CACHE_DIR=/tmp/uv-cache
RUN apk add --no-cache --upgrade \
	coreutils-env \
	ffmpeg \
	jq \
	mediainfo \
	mkvtoolnix \
	shadow \
	sox
RUN groupadd -g 568 apps && useradd --no-log-init -r -u 568 -g apps apps
COPY --link --chmod=755 ./entrypoint.sh /usr/local/bin/entrypoint.sh
COPY --link --chmod=755 ./analyze_audio.sh /usr/local/lib/sox/analyze_audio.sh
COPY --link --chmod=755 ./annotate_waveform.py /usr/local/lib/sox/annotate_waveform.py
RUN uv sync --script /usr/local/lib/sox/annotate_waveform.py && chmod -R a+rwX "$UV_CACHE_DIR"
WORKDIR /opt/media
ENTRYPOINT ["entrypoint.sh"]
