#!/usr/bin/env bash
apt-get update && apt-get upgrade -y;
apt-get install -y git-buildpackage;                            # Needed for all packages
apt-get install -y libssl-dev bc pkg-config build-essential;    # Needed for the kernel
# Check if we're running in docker or a chroot
if [[ $(ls /proc | wc -l) -gt 0 ]]; then
    # Only needed in the docker container
    apt-get install -y debootstrap qemu qemu-user-static;
else
    # Only needed in the arm64 chroot
    apt-get install -y linux-image-arm64;
fi


# Sets the configuration files for devbuilder and gbp
set_config_files () {
# gbp configuration file
cat <<EOF > $HOME/.gbp.conf
[DEFAULT]
cleaner = fakeroot debian/rules clean
ignore-new = True

[buildpackage]
export-dir = /gbp-build-area/

EOF
# Insert a postbuild command into the middle of the gbp configuration file
# This indicates to the arm64 chroot which repositories need to be built
if [[ $(ls /proc | wc -l) -gt 0 ]]; then
    # In docker, mark repositories to be built
    echo "postbuild=touch ../\$(basename \`pwd\`)-update" >> $HOME/.gbp.conf
else
    # In chroot, mark built repositories
    echo "postbuild=rm ../\$(basename \`pwd\`)-update" >> $HOME/.gbp.conf
fi
cat <<EOF >> $HOME/.gbp.conf
[git-import-orig]
dch = False
EOF

# devbuilder configuration file
cat <<EOF > $HOME/.devscripts
DEBUILD_DPKG_BUILDPACKAGE_OPTS="-us -uc -i -b --jobs=$CORES"
EOF
}


# Check for prerequisite build packages, and install them
run_update () {
    ( git checkout upstream 2>/dev/null );
    ( git checkout debian 2>/dev/null );
    ( ls debian &>/dev/null ) && \
    ( ( dpkg-checkbuilddeps &>/dev/null ) || \
    ( echo "y" | mk-build-deps -i -r ) )
}


# Builds a new debian/rules file for nvml
fix_nvml_rules () {
read -r -d '' rule<<"EOF"
#!/usr/bin/make -f
%:
\tdh \$@

override_dh_auto_install:
\tdh_auto_install -- prefix=/usr

override_dh_install:
\tmkdir -p debian/tmp/usr/share/nvml/
\tcp utils/nvml.magic debian/tmp/usr/share/nvml/
\tmv debian/tmp/usr/lib64 debian/tmp/usr/lib
\tdh_install

override_dh_auto_test:
\techo "We do not test this code yet."

override_dh_clean:
\tfind src/ -name 'config.status' -delete
\tfind src/ -name 'config.log' -delete
\tdh_clean
EOF
echo -e "$rule" > /tmp/rules
chmod +x /tmp/rules
}


# Sets $path to the path if a build is required or "" if no build is required
# Call with a github repository URL, example:
# get_update_path https://github.com/FabricAttachedMemory/l4fame-build-container.git
get_update_path () {
    # Get a path from the git URL
    path="/build/"`echo "$1" | cut -d '/' -f 5 | cut -d '.' -f 1`;
    # Check if we're running in docker or a chroot
    if [[ $(ls /proc | wc -l) -gt 0 ]]; then
        # Check if the repository needs to be cloned, then clone
        ls $path &>/dev/null;
        if [ "$?" != "0" ]; then
            git clone "$1";
        else
            # Check if there is an update, then update
            cd $path;
            set -- `git pull`;
            if [ "$1" != "Updating" ]; then
                path="./";
            fi
        fi
    else
        # Check if docker marked the repository as needing a rebuild
        ls $path"-update" &>/dev/null;
        if [ "$?" != "0" ]; then
            path="./";
        fi
    fi
}


# If user sets "-e cores=number_of_cores" use that many cores when compiling
if [ "$cores" ]; then
    CORES=$(( $cores ))
# Otherwise set $CORES to half the cpu cores.
else
    CORES=$(( ( `nproc` + 1 ) / 2 ))
fi

# Check if we're running in docker or a chroot
if [[ $(ls /proc | wc -l) -gt 0 ]]; then
    # Build an arm64 chroot if none exists
    ( ls /arm64 &>/dev/null ) || qemu-debootstrap --arch=arm64 unstable /arm64/jessie http://deb.debian.org/debian/;
    # Make the directories that gbp will download repositories to and build in
    mkdir -p /deb;
    mkdir -p /build;
    mkdir -p /deb/arm64;
    mkdir -p /arm64/jessie/deb;
    mkdir -p /arm64/jessie/build;
    # Mount /deb and /build so we can get at them from inside the chroot
    mount --bind /deb/arm64 /arm64/jessie/deb;
    mount --bind /build /arm64/jessie/build;
    # Copy this script into the chroot
    cp "$0" /arm64/jessie
fi

# Change into build directory and set the configuration files
cd /build;
set_config_files;


fix_nvml_rules;
get_update_path https://github.com/FabricAttachedMemory/nvml.git;
( cd $path && run_update && gbp buildpackage --git-prebuild='mv /tmp/rules debian/rules' );

get_update_path https://github.com/FabricAttachedMemory/tm-librarian.git;
( cd $path && run_update && gbp buildpackage );

get_update_path https://github.com/keith-packard/tm-manifesting.git;
( cd $path && run_update && gbp buildpackage --git-upstream-branch=master --git-upstream-tree=branch );

get_update_path https://github.com/FabricAttachedMemory/l4fame-node.git;
( cd $path && run_update && gbp buildpackage );

get_update_path https://github.com/FabricAttachedMemory/l4fame-manager.git;
( cd $path && run_update && gbp buildpackage );

get_update_path https://github.com/FabricAttachedMemory/tm-hello-world.git;
( cd $path && run_update && gbp buildpackage );

get_update_path https://github.com/FabricAttachedMemory/tm-libfuse.git;
( cd $path && run_update && gbp buildpackage );

get_update_path https://github.com/FabricAttachedMemory/libfam-atomic.git;
( cd $path && run_update && gbp buildpackage --git-upstream-tree=branch );

get_update_path https://github.com/FabricAttachedMemory/Emulation.git;
( cd $path && run_update && gbp buildpackage --git-upstream-branch=master );

# Copy all the built .deb's to the external deb folder
cp /gbp-build-area/*.deb /deb;


# Build with config.l4fame in docker and defconfig in chroot
get_update_path https://github.com/FabricAttachedMemory/linux-l4fame.git;
if [[ $(ls /proc | wc -l) -gt 0 ]]; then
    ( cd $path && cp config.l4fame .config && make -j $CORES deb-pkg );
else
    ( cd $path && make -j $CORES defconfig deb-pkg );
fi
cp /build/*.deb /deb;


# Change into the chroot and run this script
set -- `basename $0`
if [[ $(ls /proc | wc -l) -gt 0 ]]; then
    chroot /arm64/jessie "/$1" 'cores=$CORES' 'http_proxy=$http_proxy' 'https_proxy=$https_proxy'
fi
