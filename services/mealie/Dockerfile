# Mealie, rebuilt for an x86-64-v1 host.
#
# skypaw-lab runs on an AMD Turion II Neo N54L (HP MicroServer), which
# predates SSE4.2 and has no AVX. NumPy 2.x publishes manylinux wheels
# compiled with an SSE4.2 baseline, so `import numpy` raises SIGILL on
# this CPU and the container dies with exit code 132 before Python can
# log anything. With `restart: unless-stopped` that becomes a silent
# crash-loop roughly every 13 seconds, pinning a core indefinitely.
#
# NumPy is a transitive dependency only (RapidFuzz, pillow_heif, openai,
# nltk, ingredient_parser_nlp, Pint), so pinning it back to the 1.x
# series restores a working image. `pip check` reports no broken
# requirements after the downgrade.
#
# The base tag is pinned deliberately. Mealie ships :latest and watchtower
# used to update it unattended, which is how the v3.15.0 -> v3.19.2 drift
# broke this service on 2026-04-14 and left it down until it was noticed.
# Bump this tag by hand, rebuild, and check the container reaches
# "Application startup complete." before considering it done.
FROM ghcr.io/mealie-recipes/mealie:v3.19.2

USER root
RUN pip install --no-cache-dir "numpy<2"
USER 911
