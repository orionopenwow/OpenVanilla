# A small image that can rebuild realm/classicplus/patch-Z.MPQ anywhere Docker runs (Windows too).
#   docker build -t openvanilla-patchz devkit/patchz
#   docker run --rm -v "%cd%":/repo openvanilla-patchz              (Dev.bat option 8 does both)
# StormLib is built from source at a pinned commit (the same one the patch has been built with).
FROM debian:bookworm-slim
RUN apt-get update -qq && apt-get install -y -qq --no-install-recommends \
      ca-certificates git cmake g++ make zlib1g-dev libbz2-dev python3 >/dev/null \
 && git clone -q https://github.com/ladislav-zezula/StormLib /src/StormLib \
 && git -C /src/StormLib checkout -q 116135c27e8c0dcf8ea0a0c549a6d737ce10fc73 \
 && cmake -S /src/StormLib -B /src/StormLib/build -DBUILD_SHARED_LIBS=ON -DCMAKE_BUILD_TYPE=Release >/dev/null \
 && cmake --build /src/StormLib/build -j4 >/dev/null \
 && cp /src/StormLib/build/libstorm.so* /usr/local/lib/ && ldconfig \
 && rm -rf /src /var/lib/apt/lists/*
ENV STORMLIB=/usr/local/lib/libstorm.so
WORKDIR /repo
CMD ["python3", "tools/sync_patchz.py"]
