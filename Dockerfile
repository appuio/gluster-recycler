FROM docker.io/library/centos:7

RUN \
  set -e && \
  PRE_INSTALL_PKG=" \
    https://dl.fedoraproject.org/pub/epel/epel-release-latest-7.noarch.rpm" && \
  if ( . /etc/os-release && [ "$NAME" = rhel ] ); then \
    extrapkg=http://mirror.centos.org/centos/7/extras/x86_64/Packages && \
    PRE_INSTALL_PKG="${PRE_INSTALL_PKG} \
      ${extrapkg}/centos-release-storage-common-2-2.el7.centos.noarch.rpm \
      ${extrapkg}/centos-release-gluster5-1.0-1.el7.centos.noarch.rpm \
      "; \
  else \
    PRE_INSTALL_PKG="${PRE_INSTALL_PKG} centos-release-gluster5"; \
  fi && \
  yum install -y --setopt=tsflags=nodocs $PRE_INSTALL_PKG && \
  INSTALL_PKGS="bash tar jq findutils which glusterfs-fuse glusterfs-cli" && \
  yum install -y --setopt=tsflags=nodocs $INSTALL_PKGS && \
  rpm -V $INSTALL_PKGS && \
  yum clean all

ENV TINI_VERSION v0.18.0
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini /tini
ADD https://github.com/krallin/tini/releases/download/${TINI_VERSION}/tini.asc /tini.asc
RUN \
  gpg --keyserver hkp://p80.pool.sks-keyservers.net:80 --recv-keys 595E85A6B1B4779EA4DAAEC70B588DFF0527A9B7 && \
  gpg --verify /tini.asc
RUN chmod +x /tini
ENTRYPOINT ["/tini", "--"]

RUN mkdir -p /var/lib/glusterd

ADD recycler.sh /
CMD /recycler.sh
