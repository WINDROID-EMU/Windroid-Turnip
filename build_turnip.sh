#!/bin/bash -e
set -o pipefail

deps="git meson ninja patchelf unzip curl pip flex bison zip glslangValidator python3"
scriptdir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
workdir="$(pwd)/turnip_workdir"
ndkver="android-ndk-r29"
ndk="$workdir/$ndkver/toolchains/llvm/prebuilt/linux-x86_64/bin"
mesasrc="https://gitlab.freedesktop.org/mesa/mesa.git"
mesatag="mesa-25.1.4"
srcfolder="mesa"
BUILD_VERSION="${BUILD_VERSION:-1.0}"

# Patches que aplicam limpo em cima do gen8 atual (testados manualmente, um a um E em
# sequência - houve conflito real entre dois deles, ver nota abaixo).
# Os demais patches do repo (tu_gen8.patch, tu_gen8_clean.patch, tu8_kgsl_26.patch,
# disable_vkQueueSubmit2.patch) jã estã incorporados no branch gen8 ou duplicados
# por outro fix neste script, e por isso NÃO entram aqui.
#
# NOTA: patches/texture_quality_reduction.patch NÃO entra aqui de propósito - ele mexe
# NOTA: patches/texture_quality_reduction.patch NÃƒO entra aqui de propÃ³sito - ele mexe
# nas MESMAS linhas de tu_sampler.cc que windroid_perf_hacks.patch (os dois calculam
# lod_bias de formas diferentes e incompatÃ­veis), entÃ£o aplicar os dois juntos gera
# conflito de verdade, nÃ£o sÃ³ de contexto. Ficou de fora atÃ© alguÃ©m decidir como
# mesclar as duas features (hack fixo de LOD vs. controle por env var).
patches_to_apply=(
    "$scriptdir/windroid_perf_hacks.patch"
    "$scriptdir/patches/polygon_reduction_vrs.patch"
)

run_all(){
    check_deps
    prepare_workdir
    check_driver_version
    apply_patches
    build_lib_for_android gen8
}

check_driver_version(){
    cd "$workdir/$srcfolder"
    local ver
    ver=$(cat VERSION 2>/dev/null || echo "desconhecida")
    echo "VersÃ£o do driver (Mesa/turnip) detectada: $ver"
    case "$ver" in
        26.*)
            echo "AVISO: fonte na sÃ©rie 26.x. Mantendo assim de propÃ³sito, pois Ã© onde" \
                 "o suporte a8xx/gen8 existe (ver comentÃ¡rio sobre mesabranch no topo do script)."
            ;;
        25.*)
            echo "AVISO: fonte na sÃ©rie 25.x - o suporte a8xx/gen8 NÃƒO existe aqui." \
                 "Os patches de gen8 vÃ£o falhar ao aplicar. Confira mesabranch."
            ;;
    esac
}

apply_patches(){
    cd "$workdir/$srcfolder"
    for p in "${patches_to_apply[@]}"; do
        [ -f "$p" ] || { echo "Patch nÃ£o encontrado, pulando: $p"; continue; }
        if git apply --check "$p" &>/dev/null; then
            echo "Aplicando patch: $(basename "$p")"
            git apply "$p"
        elif git apply --reverse --check "$p" &>/dev/null; then
            echo "Patch jÃ¡ aplicado, pulando: $(basename "$p")"
        else
            echo "AVISO: patch nÃ£o aplica (conflito), pulando: $(basename "$p")"
        fi
    done
}

check_deps(){
    for deps_chk in $deps; do
        if ! command -v "$deps_chk" >/dev/null 2>&1 ; then
            exit 1
        fi
    done
    pip install mako --break-system-packages &> /dev/null || true
}

prepare_workdir(){
    mkdir -p "$workdir" && cd "$workdir"

    if [ ! -d "$ndkver" ]; then
        echo "Baixando NDK..."
        curl -sL "https://dl.google.com/android/repository/${ndkver}-linux.zip" -o "${ndkver}-linux.zip" &> /dev/null
        unzip -q "${ndkver}-linux.zip" &> /dev/null
        rm "${ndkver}-linux.zip"
    fi

    if [ ! -d "$srcfolder" ]; then
        echo "Baixando código fonte do Mesa..."
        git clone "$mesasrc" --depth=1 --branch "$mesatag" "$srcfolder"
    else
        echo "CÃ³digo fonte jÃ¡ existe, pulando download."
    fi
    
    cd "$srcfolder"
    
    echo "#define TUGEN8_DRV_VERSION \"\"" > ./src/freedreno/vulkan/tu_version.h
}

build_lib_for_android(){
    cd "$workdir/$srcfolder"
    # git checkout -f "origin/$1" # Comentado para preservar as otimizaÃ§Ãµes manuais

    sed -i 's/ (%s)//g' src/freedreno/vulkan/tu_device.cc || true
    sed -i 's/ (%s)//g' src/freedreno/vulkan/tu_device.c || true

    # FIX: Disable VK_KHR_synchronization2 to fix winevulkan vkQueueSubmit2 crash
    sed -i 's/\.KHR_synchronization2 = true,/.KHR_synchronization2 = false,/g' src/freedreno/vulkan/tu_device.cc || true

    grep -q "has_early_preamble = False," src/freedreno/common/freedreno_devices.py || sed -i '/a7xx_gen1 = GPUProps(/a \        has_early_preamble = False,' src/freedreno/common/freedreno_devices.py || true
    sed -i 's/typedef const native_handle_t\* buffer_handle_t;/typedef void\* buffer_handle_t;/g' include/android_stub/cutils/native_handle.h || true
    sed -i 's/, hnd->handle/, (void \*)hnd->handle/g' src/util/u_gralloc/u_gralloc_fallback.c || true
    sed -i 's/native_buffer->handle->/((const native_handle_t \*)native_buffer->handle)->/g' src/vulkan/runtime/vk_android.c || true
    sed -i 's/anb->handle->/((const native_handle_t \*)anb->handle)->/g' src/vulkan/runtime/vk_android.c || true

    mkdir -p "$workdir/bin"
    ln -sf "$ndk/clang" "$workdir/bin/cc"
    ln -sf "$ndk/clang++" "$workdir/bin/c++"
    export PATH="$workdir/bin:$ndk:$PATH"
    export CC=clang
    export CXX=clang++
    export AR=llvm-ar
    export RANLIB=llvm-ranlib
    export STRIP=llvm-strip
    export OBJDUMP=llvm-objdump
    export OBJCOPY=llvm-objcopy
    export LDFLAGS="-fuse-ld=lld"

    GITHASH=$(git rev-parse --short HEAD)

    local cver="36"
    [ ! -f "$ndk/aarch64-linux-android${cver}-clang" ] && cver="35"
    [ ! -f "$ndk/aarch64-linux-android${cver}-clang" ] && cver="34"

    cat <<EOF >"android-aarch64.txt"
[binaries]
ar = '$ndk/llvm-ar'
c = ['ccache', '$ndk/aarch64-linux-android${cver}-clang']
cpp = ['ccache', '$ndk/aarch64-linux-android${cver}-clang++', '-fno-exceptions', '-fno-unwind-tables', '-fno-asynchronous-unwind-tables', '--start-no-unused-arguments', '-static-libstdc++', '--end-no-unused-arguments']
c_ld = '$ndk/ld.lld'
cpp_ld = '$ndk/ld.lld'
strip = '$ndk/llvm-strip'
pkg-config = ['env', 'PKG_CONFIG_LIBDIR=$ndk/pkg-config', '/usr/bin/pkg-config']

[host_machine]
system = 'android'
cpu_family = 'aarch64'
cpu = 'armv8'
endian = 'little'
EOF

    cat <<EOF >"native.txt"
[build_machine]
c = ['ccache', 'clang']
cpp = ['ccache', 'clang++']
ar = 'llvm-ar'
strip = 'llvm-strip'
c_ld = 'ld.lld'
cpp_ld = 'ld.lld'
system = 'linux'
cpu_family = 'x86_64'
cpu = 'x86_64'
endian = 'little'
EOF

    meson setup build-android-aarch64 \
        --cross-file "android-aarch64.txt" \
        --native-file "native.txt" \
        --prefix "/tmp/turnip-$1" \
        -Dbuildtype=release \
        -Dstrip=true \
        -Dplatforms=android \
        -Dvideo-codecs= \
        -Dplatform-sdk-version=36 \
        -Dandroid-stub=true \
        -Dgallium-drivers= \
        -Dvulkan-drivers=freedreno \
        -Dvulkan-beta=true \
        -Dfreedreno-kmds=kgsl \
        -Degl=disabled \
        -Dandroid-libbacktrace=disabled

    ninja -C build-android-aarch64 install

    if [ ! -f "/tmp/turnip-$1/lib/libvulkan_freedreno.so" ]; then
        exit 1
    fi

    cd "/tmp/turnip-$1/lib"
    
    cat <<EOF >"meta.json"
{
  "schemaVersion": 1,
  "name": "Turnip Gen8 V29",
  "description": "A8xx support",
  "author": "stevenmx",
  "packageVersion": "1",
  "vendor": "Mesa",
  "driverVersion": "Vulkan 1.4.348",
  "minApi": 28,
  "libraryName": "libvulkan_freedreno.so"
}
EOF

    zip -9 "/tmp/a8xx-$1-V${BUILD_VERSION}.zip" libvulkan_freedreno.so meta.json
    cp "/tmp/a8xx-$1-V${BUILD_VERSION}.zip" "$workdir/"
    cp "/tmp/a8xx-$1-V${BUILD_VERSION}.zip" "./"
    echo "Driver gerado em: $(pwd)/a8xx-$1-V${BUILD_VERSION}.zip"
}

run_all
