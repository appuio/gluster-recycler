FROM gluster/gluster-centos
ADD jq-linux64 /usr/bin/jq
ADD recycler.sh /
