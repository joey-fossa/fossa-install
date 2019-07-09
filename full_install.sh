#!/bin/bash
if [ "$(id -u)" != "0" ]; then
exec sudo "$0" "$@"
fi

#Check for EC2
#Set Environment Variables
read -p "Install in EC2 (y/n)? " answer
case ${answer:0:1} in
    y|Y )
        #export PRIMARY_IP=$(curl http://169.254.169.254/latest/meta-data/public-ipv4)
        export PRIMARY_IP=$(curl http://169.254.169.254/latest/meta-data/local-ipv4)
        #Update db_host with EC2 IP if EC2
    sudo -E sed -i "s/db__host=db/db__host=$PRIMARY_IP/g" ~/fossa/config.env
    sudo -E sed -i "s/app__hostname=localhost/app__hostname=$PRIMARY_IP/g" ~/fossa/config.env
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
mkdir -p ~/fossa && curl -L https://github.com/fossas/fossa-installer/archive/v0.0.21.tar.gz | tar -zxv -C ~/fossa --strip-components=1 && chmod a+x ~/fossa/boot.sh && sudo ln -sf ~/fossa/boot.sh /usr/local/bin/fossa && cd ~/fossa
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
#Run Minio with Access Keys
echo "Run Minio Docker Container"
sudo /usr/bin/docker run -p 9000:9000 --name minio1 -e "MINIO_ACCESS_KEY=AKIAIOSFODNN7EXAMPLE" -e "MINIO_SECRET_KEY=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY" -v /mnt/data:/data -v /mnt/config:/root/.minio minio/minio server /data &  
  sleep 10s
#Create cache and archive buckets in minio container
echo "Add Minio buckets"
sudo docker run --net=host -it --entrypoint=/bin/sh minio/mc -c "\
  mc config host add minio1 http://127.0.0.1:9000 \AKIAIOSFODNN7EXAMPLE \wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY && \
  mc mb minio1/cache.fossa.io && \
  mc mb minio1/archive.fossa.io && \  
  exit" 
echo "Start Minio container"
  #Start minio
  sleep 10s
  sudo /usr/bin/docker start minio1

################################################################################################
#backup config.env
sudo cp ~/fossa/config.env ~/fossa/config.env.bak

################################################################################################
#Append config.env file with S3 config info
sudo echo "# Package caching" >> ~/fossa/config.env
sudo echo "cache__package__engine=s3" >> ~/fossa/config.env
sudo echo "cache__package__bucket=cache.fossa.io"  >> ~/fossa/config.env
sudo echo "cache__package__s3Options__accessKeyId=AKIAIOSFODNN7EXAMPLE"  >> ~/fossa/config.env
sudo echo "cache__package__s3Options__secretAccessKey=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"  >> ~/fossa/config.env
sudo echo -E "cache__package__s3Options__endpoint="$PRIMARY_IP":9000"  >> ~/fossa/config.env
sudo echo "cache__package__s3Options__s3ForcePathStyle=true"  >> ~/fossa/config.env
sudo echo "# To store private code"  >> ~/fossa/config.env
sudo echo "cache__package__store_private=true"  >> ~/fossa/config.env

sudo echo "# Archive Uploading (may differ from Package Caching config)"  >> ~/fossa/config.env
sudo echo "s3__accessKeyId=AKIAIOSFODNN7EXAMPLE"  >> ~/fossa/config.env
sudo echo "s3__secretAccessKey=wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"  >> ~/fossa/config.env
sudo echo -E "s3__endpoint="$PRIMARY_IP":9000"  >> ~/fossa/config.env
sudo echo "componentUploader__bucket=archive.fossa.io"  >> ~/fossa/config.env

################################################################################################
sudo service postgresql stop

################################################################################################
#(cd ~/fossa;sudo fossa start 1) > /dev/null 2>&1 & disown

#(cd ~/fossa;sudo fossa start 1) > /dev/null 2>&1 & disown