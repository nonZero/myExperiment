#!/bin/bash

echo ""
echo "+----------------------------------------------------------------------------------------------+"
echo "|                  Welcome to the myExperimemt Installer for Ubuntu 10.04!                     |"
echo "|  Go to http://wiki.myexperiment.org/index.php/Developer:UbuntuInstallation for more details. |"
echo "+----------------------------------------------------------------------------------------------+"
echo ""

settings_file=`dirname $0`/settings.bash 
source $settings_file || { echo "Could not find settings file at $settings_file. Aborting ..."; exit 1; }

echo "Preseeding debconf"
sudo su -c "/usr/share/debconf/fix_db.pl" || { echo "Failed to run debconf fix_db script. Aborting ..."; exit 2; }
sudo su -c "echo mysql-server-5.1 mysql-server/root_password password `echo "'"``echo ${mysql_root_password}``echo "'"` | debconf-set-selections" || { echo "Failed to set debconf option. Aborting ..."; exit 3; }
sudo su -c "echo mysql-server-5.1 mysql-server/root_password_again password `echo "'"``echo ${mysql_root_password}``echo "'"` | debconf-set-selections" || { echo "Failed to set debconf option. Aborting ..."; exit 3; }

echo "Installing required APT packages"
sudo apt-get update || { echo "Failed to update apt-get. Aborting ..."; exit 4; }
sudo -n apt-get install -y build-essential exim4 ruby ruby1.8-dev libzlib-ruby rdoc irb rubygems rake libapache2-mod-fcgid libfcgi-ruby1.8 libmysql-ruby gcj-4.4-jre-headless subversion libopenssl-ruby1.8 libcurl3 libcurl3-gnutls libcurl4-openssl-dev mysql-server graphicsmagick imagemagick librmagick-ruby1.8 libmagick9-dev graphviz || { echo "Failed to installing required APT packages. Aborting ..."; exit 5; }

echo "Installing Rake version $rake_version and Rails version $rails_version Ruby Gems"
sudo gem install rake $nordoc $nori --version $rake_version || { echo "Could not install Rake Ruby Gem (version $rake_version). Aborting ..."; exit 6; }
sudo gem install rails $nordoc $nori --version $rails_version || { echo "Failed to install Rails Ruby Gem (v$rails_version) and dependencies. Aborting ..."; exit 7; }

echo "Installing Ruby Gems required by myExperiment"
sudo gem install $nordoc $nori rdoc rdoc-data  || { echo "Could not install RDoc Ruby Gems.  Aborting ..."; exit 40;}
if [ `cat /etc/environment | grep "/var/lib/gems/1.8/bin" | wc -l` -eq 0 ]; then
	cat /etc/environment | sed "s/\"$/:\/var\/lib\/gems\/1.8\/bin\"/" | sudo tee /etc/environment > /dev/null || { echo "Could not add Gems path to PATH.  Aborting ..."; exit 33;}
fi
if [ `echo $PATH | grep "/var/lib/gems/1.8/bin" | wc -l` -eq 0 ]; then
	DOLLAR='$'; echo -e "export PATH=${DOLLAR}PATH:/var/lib/gems/1.8/bin\nalias sudo='sudo env PATH=${DOLLAR}PATH'" >> /home/$USER/.bashrc || { echo "Could not write to /home/$USER/.bashrc.  Aborting ..."; exit 38;}
	export PATH=$PATH:/var/lib/gems/1.8/bin
fi
sudo env PATH=$PATH rdoc-data --install ||  { echo "Could not install rdoc-data. Aborting ..."; exit 9; }
if [ "$nordoc" -eq 0 ]; then
        sudo gem rdoc --all --overwrite || { echo "Could overwrite RDoc for existing Ruby Gems. Aborting ..."; exit 39; }
fi
sudo gem install $nordoc $nori cgi_multipart_eof_fix daemons dsl_accessor fastthread gem_plugin json mime-types mongrel mongrel_cluster needle net-sftp net-ssh openid_login_generator RedCloth ruby-yadis rubyzip solr-ruby xml-simple libxml-ruby oauth ruby-hmac openurl curb marc taverna-scufl taverna-t2flow || { echo "Failed to install all remaining generic Ruby Gems required by myExperiment. Aborting ..."; exit 8; }
sudo gem install rmagick $nordoc $nori --version=1.15.14 || { echo "Failed to install RMagick Ruby Gem. Aborting ..."; exit 10; }

echo "Making OAuth Ruby Gem compatible with Rails $version"
tempdir=$(mktemp -d /tmp/myexp_installer.XXXXXXXXXX) || { echo "Could not create temporary file for writing patches to. Aborting ..."; exit 11; }
cd $tempdir || { echo "Could not find temporary directory. Aborting ..."; exit 12; }
echo "$oauth_patch" > oauth.patch || { echo "Could not write oauth patch file. Aborting ..."; exit 13; }
echo "$net_http_patch" > net_http.patch || { echo "Could not write net/http patch file. Aborting ..."; exit 14; }
echo "$settings_patch" > settings.patch || { echo "Could not write settings patch file. Aborting ..."; exit 15; }
sudo updatedb || { echo "Failed to run updatedb so that OAuth Ruby Gem file that needs updating can be located. Aborting ..."; exit 16; }
oauth_file=`locate lib/oauth/request_proxy/action_controller_request.rb`
if [ ! -e $oauth_file ]; then 
	echo "Could not locate OAuth Ruby Gem file that requires updating. Aborting ..."; exit 17;
fi
sudo patch $oauth_file $tempdir/oauth.patch || { echo "Could not patch OAuth Ruby Gem file: $oauth_file. Aborting ..."; exit 18; }
net_http_file=`locate net/http.rb`
if [ ! -e $net_http_file ]; then
        echo "Could not locate net/http Ruby file that requires updating. Aborting ..."; exit 19;
fi
sudo patch $net_http_file $tempdir/net_http.patch || { echo "Could not patch net/http Ruby file: $net_http_file. Aborting ..."; exit 20; }

echo "Checking out myExperiment codebase from SVN"
cd /
for idir in `echo $install_dir | awk 'BEGIN{RS="/"}{print $1}'`; do
	if [ -n $idir ]; then
		sudo mkdir $idir
		cd $idir
	fi
done
sudo chown $USER:www-data $install_dir || { echo "Could not update permissions on $install_dir. Aborting ..."; exit 21; }
svn checkout svn://rubyforge.org/var/svn/myexperiment/trunk $install_dir || { echo "Could not checkout SVN to $install_dir. Aborting ..."; exit 22; }
cd ${install_dir}/config/ || { echo "Could not find config directory for myExperiment. Aborting ..."; exit 23; }

echo "Setting up config files for myExperiment"
cat database.yml.pre | sed "s/username: root/username: $mysql_user_name/" | sed "s/password:/password: $mysql_user_password/" > database.yml || { echo "Could not create database.yml file with appropriate configuration settings. Aborting ..."; exit 24; }
cp default_settings.yml settings.yml || { echo "Could not copy default_settings.yml to settings.yml ..."; exit 25; }
patch settings.yml $tempdir/settings.patch  || { echo "Could not patch settings.yml. Aborting ..."; exit 26; }
cp captcha.yml.pre captcha.yml || { echo "Could not create captcha.yml file.  Aborting ..."; exit 27; }
cd ..

echo "Setting up exim4 (Email) for myExperiment"
echo "dc_eximconfig_configtype='satellite'
dc_other_hostnames='${fq_server_name}'
dc_local_interfaces='127.0.0.1 ; ::1'
dc_readhost='${fq_server_name}'
dc_relay_domains=''
dc_minimaldns='false'
dc_relay_nets=''
dc_smarthost='${exim_smarthost}'
CFILEMODE='644'
dc_use_split_config='false'
dc_hide_mailname='true'
dc_mailname_in_oh='true'
dc_localdelivery='mail_spool'" | sudo tee /etc/exim4/update-exim4.conf.conf > /dev/null  || { echo "Could not write new exim4 config.  Aborting..."; exit 28; }
echo "${fq_server_name}" | sudo tee /etc/mailname > /dev/null  || { echo "Could not update hostname for /etc/mailname.  Aborting..."; exit 29; }
sudo dpkg-reconfigure -fnoninteractive exim4-config || { echo "Could not write new reconfingure exim4.  Aborting..."; exit 30; }

echo "Setting up myExperiment databases in MySQL"
mysql -u root -p$mysql_root_password -e "CREATE USER '$mysql_user_name'@'localhost' IDENTIFIED BY '$mysql_user_password'; CREATE DATABASE m2_development; CREATE DATABASE m2_production; CREATE DATABASE m2_test; GRANT SELECT,INSERT,UPDATE,DELETE,CREATE,INDEX,ALTER,DROP,CREATE TEMPORARY TABLES,CREATE VIEW,SHOW VIEW ON m2_development . * TO '$mysql_user_name'@'localhost';GRANT SELECT,INSERT,UPDATE,DELETE,CREATE,INDEX,ALTER,DROP,CREATE TEMPORARY TABLES,CREATE VIEW,SHOW VIEW ON m2_production . * TO '$mysql_user_name'@'localhost';GRANT SELECT,INSERT,UPDATE,DELETE,CREATE,INDEX,ALTER,DROP,CREATE TEMPORARY TABLES,CREATE VIEW,SHOW VIEW ON m2_test . * TO '$mysql_user_name'@'localhost';" || { echo "Could not create myExperiment databases in MySQL and set up appropriate access for the $mysql_user_name user. Aborting ..."; exit 23; }

echo "Migrating myExperiment database"
rake db:migrate || { echo "Could not migrate myExperiment data model to a MySQL database. Aborting ..."; exit 31; }

echo "Starting Solr (search) server and indexing"
rake solr:start || { echo "Could not start Solr server. Aborting ..."; exit 32; }

echo "Starting Mongrel webserver as a daemon running myExperiment website"
ruby script/server -d || { echo "Could not start Mongrel Webserver for myExperiment website. Aborting ..."; exit 35; }

echo "Removing temporary directory created for writing patch files to"
sudo rm -rf $tempdir || { echo "Could not remove temporary directory used by patch files."; echo exit 36; }

echo "+--------------------------------------------------------------------------------------------+"
echo "|  myExperiment is now fully installed. Go to http://localhost:3000 to use myExperiment      |"
echo "|  Or substitute for the server name if you have installed myExperiment on a separate server |" 
echo "+--------------------------------------------------------------------------------------------+"