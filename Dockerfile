FROM gluster/gluster-centos


RUN INSTALL_PKGS="bash tar jq" && \
    yum install -y $INSTALL_PKGS && \
    rpm -V $INSTALL_PKGS && \
yum clean all

#ADD jq-linux64 /usr/bin/jq
ADD recycler.sh /
