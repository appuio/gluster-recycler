FROM centos:7

RUN INSTALL_PKGS="bash tar jq findutils which glusterfs-fuse" && \
    rpm -ihv https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm && \
    yum install -y --setopt=tsflags=nodocs $INSTALL_PKGS && \
    rpm -V $INSTALL_PKGS && \
    yum clean all

ADD recycler.sh /
CMD /recycler.sh
