#!/bin/bash
if [ "$(id -u)" != "0" ]; then
exec sudo "$0" "$@"
fi
cd /opt/

#Prompt for SSL/TLS support
read -p "Install SSL/TLS Certificates (y/n)? " tls_answer
#Prompt for certs copied to server and cert
read -p "Have you copied certificates to this server and do you know the path and file names (y/n)? " cert_answer
case ${cert_answer:0:1} in
    y|Y )
      #Do Nothing
    ;;
    * )
      exit 0;;
esac

case ${tls_answer:0:1} in
    y|Y )
        read -ep "Enter directory path for TLS and SSL Certs (Example: /xxx/yyy/certs) " file_dir
        #capture key file name
        read -ep "Enter the file name of your key file " key
        #capture certificate file name
        read -ep "Enter the file name of your certificate file " cert
    ;;
    * )
        ##Do nothing
    ;;
esac
#Check for EC2
#Set Environment Variables
read -p "Install in EC2 (y/n)? " ec2_answer
case ${ec2_answer:0:1} in
    y|Y )
        export PRIMARY_IP=$(curl http://169.254.169.254/latest/meta-data/public-ipv4)
        #export PRIMARY_IP=$(curl http://169.254.169.254/latest/meta-data/local-ipv4)
    ;;
    * )
        export PRIMARY_IP=$(ip route get 1 | awk '{print $NF;exit}')
    ;;
esac
#Update packages
sudo apt-get update -y
#Install expect
sudo apt-get install -y expect
################################################################################################
#Install Docker
sudo apt-get -y install docker.io
#Create links
sudo ln -sf /usr/bin/docker.io /usr/local/bin/docker

################################################################################################
#Install PostgreSQL
sudo apt-get -y install postgresql postgresql-contrib

################################################################################################
# Download and run the installer
mkdir -p /opt/fossa && curl -L https://github.com/fossas/fossa-installer/archive/v0.0.21.tar.gz | tar -zxv -C /opt/fossa --strip-components=1 && chmod a+x /opt/fossa/boot.sh && sudo ln -sf /opt/fossa/boot.sh /usr/local/bin/fossa && cd /opt/fossa
# Setup fossa
sudo ./setup.sh
# Add user to docker group
sudo usermod -aG docker $( id -un )
#
# Initialize fossa - This will prompt for the Quay container credentials
/usr/bin/expect -c '
set force_conservative 0  
set send_slow {1 .1}                         
#
set timeout -1
spawn sudo fossa init
match_max 100000
expect -exact "Initializing Fossa\r
Please provide docker login credentials.\r
Username: "
send -- "fossa+se\r"
expect -exact "fossa+se\r
Password: "
send -- "WF5GM4KAVLBE1VS1O4Z6V4BRG5K25P94ZY09ANW5S6A08X3OXRDZHSI3CA4YD1WO\r"
expect eof
'
################################################################################################
#Install Minio
#Install go-lang
#apt install -y golang-go
#get go script to generate cert for minio
#wget -O generate_cert.go https://golang.org/src/crypto/tls/generate_cert.go?m=text
#generate keys for Minio
#go run generate_cert.go -ca --host "127.0.0.1"
#cp /root/cert.pem /mnt/config/certs/public.crt
#cp /root/key.pem /mnt/config/certs/private.key

#Run Minio with Access Keys
echo "Run Minio Docker Container"
#line below commented until we figure out if security minio on the same server is possible
#cp $file_dir/* /mnt/config/certs/
/usr/bin/docker run -p 9000:9000 --name minio1 -e "MINIO_ACCESS_KEY=AKIAIOSFODNN7EXAMPLE" -e "MINIO_SECRET_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" -v /mnt/data:/data -v /mnt/config:/root/.minio minio/minio server /data &  
sleep 10s
#Create cache and archive buckets in minio container
echo "Add Minio buckets"
/usr/bin/docker run --net=host -it --entrypoint=/bin/sh minio/mc -c "\
  mc config host add minio1 http://127.0.0.1:9000 \AKIAIOSFODNN7EXAMPLE \wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY && \
  mc mb minio1/cache.fossa.io && \
  mc mb minio1/archive.fossa.io && \  
  exit" 

#If TLS/SSL is in play, commit the minio image configuration, stop and remove the container and start a new container with port 443
#Also copy the existing certificates to the minio required folder /mnt/config/certs with the required names of private.key and public.crt
  case ${tls_answer:0:1} in
    y|Y )
         #commit changes to mimio container  
        /usr/bin/docker commit $(docker ps --no-trunc -aqf name=minio1) minio/minio
        #stop and remove minio1
        /usr/bin/docker stop minio1
        /usr/bin/docker rm minio1
        #Copy certificate and key from base directory to minio required directory
        cp $file_dir/$key /mnt/config/certs/private.key
        cp $file_dir/$cert /mnt/config/certs/public.crt
        #Restart minio with SSL port
        /usr/bin/docker run -p 443:9000 --name minio1 -e "MINIO_ACCESS_KEY=AKIAIOSFODNN7EXAMPLE" -e "MINIO_SECRET_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" -v /mnt/data:/data -v /mnt/config:/root/.minio minio/minio server /data &  
        sleep 10s
    ;;
    * )
      #Nothing
    ;;
esac

################################################################################################
#backup config.env
sudo cp /opt/fossa/config.env /opt/fossa/config.env.bak
################################################################################################
#update config.env with EC2 settings
################################################################################################
case ${ec2_answer:0:1} in
    y|Y )
        #Update db_host with EC2 IP if EC2
      sudo -E sed -i "s/db__host=db/db__host=$PRIMARY_IP/g" /opt/fossa/config.env
      sudo -E sed -i "s/app__hostname=localhost/app__hostname=$PRIMARY_IP/g" /opt/fossa/config.env
    ;;
    * )
        #N/A
    ;;
esac
################################################################################################
#Append config.env file with S3 config info
sudo echo "# Package caching" >> /opt/fossa/config.env
sudo echo "cache__package__engine=s3" >> /opt/fossa/config.env
sudo echo "cache__package__bucket=cache.fossa.io"  >> /opt/fossa/config.env
sudo echo "cache__package__s3Options__accessKeyId=AKIAIOSFODNN7EXAMPLE"  >> /opt/fossa/config.env
sudo echo "cache__package__s3Options__secretAccessKey=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"  >> /opt/fossa/config.env
sudo echo "cache__package__s3Options__s3ForcePathStyle=true"  >> /opt/fossa/config.env
sudo echo "# To store private code"  >> /opt/fossa/config.env
sudo echo "cache__package__store_private=true"  >> /opt/fossa/config.env
sudo echo "# Archive Uploading (may differ from Package Caching config)"  >> /opt/fossa/config.env
sudo echo "s3__accessKeyId=AKIAIOSFODNN7EXAMPLE"  >> /opt/fossa/config.env
sudo echo "s3__secretAccessKey=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"  >> /opt/fossa/config.env
sudo echo "componentUploader__bucket=archive.fossa.io"  >> /opt/fossa/config.env


case ${tls_answer:0:1} in
    y|Y )
        #If SSL in play set minio endpoint ports to 443
        sudo echo -E "cache__package__s3Options__endpoint="$PRIMARY_IP":443"  >> /opt/fossa/config.env
        sudo echo -E "s3__endpoint="$PRIMARY_IP":443"  >> /opt/fossa/config.env
    ;;
    * )
        #If no SSL set minio endpoint to standard 9000
        sudo echo -E "cache__package__s3Options__endpoint="$PRIMARY_IP":9000"  >> /opt/fossa/config.env
        sudo echo -E "s3__endpoint="$PRIMARY_IP":9000"  >> /opt/fossa/config.env
    ;;
esac
################################################################################################
case ${tls_answer:0:1} in
    y|Y )
        #Backup boot.sh
        sudo cp /opt/fossa/boot.sh /opt/fossa/boot.sh.bak
        #Update boot.sh
        #Insert CERTDIR env variable after shebang
        match="env bash"
        #sed  -i "s/$match/&\n"'CERTDIR=${CERTDIR-"\/root\/fossa\/certs"}'"/" /opt/fossa/boot.sh
        CERT_TXT='CERTDIR=${CERTDIR-"'
        CERT_DIR=$CERT_TXT$file_dir"\"}"
        sed  -i "s^$match^&\n$CERT_DIR^" /opt/fossa/boot.sh

        #Insert $CERTDIR parameter in Fossa Pre-Flight container run command
        SED_VAL_TXT_PREFLIGHT=""' -v $CERTDIR:\/fossa\/certs'""
        sed  -i "s/npm run preflight/&$SED_VAL_TXT_PREFLIGHT/" /opt/fossa/boot.sh

        #Insert $CERTDIR parameter in Fossa core container run command
        SED_SRC_TXT="-p 80:80 -p 443:443"
        sed -i "s/$SED_SRC_TXT/&"' -v $CERTDIR:\/fossa\/certs'"/" /opt/fossa/boot.sh

        #Change SSL port to 8443
        sed -i 's/443:443/8443:8443/g' /opt/fossa/boot.sh

        #Backup config.env
        sudo cp /opt/fossa/config.env /opt/fossa/config.env.bak
        #Update config.env
        sudo echo "app__server__type=https" >> /opt/fossa/config.env
        sudo echo "app_redirect_server__enabled=false" >> /opt/fossa/config.env
        sudo echo "app__server__key=/fossa/certs/$key" >> /opt/fossa/config.env
        sudo echo "app__server__cert=/fossa/certs/$cert" >> /opt/fossa/config.env
    ;;
    * )
        ##Do nothing
    ;;
esac
################################################################################################
sudo service postgresql stop

################################################################################################
#(cd /opt/fossa;sudo fossa start 1) > /dev/null 2>&1 & disown
################################################################################################
echo "#########################################################################################"
echo " To start Fossa issue the following command.  The trailing number specifies the number of"
echo " search agents to initiate.  4 is the default"
echo "cd /opt/fossa:sudo fossa start 4"
echo "#########################################################################################"
################################################################################################