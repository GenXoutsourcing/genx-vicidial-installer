# GenX VICIdial Installer

## Platform

* AlmaLinux 9
* PHP 8.2
* MariaDB 10.11
* Asterisk 18.21
* DAHDI 3.4

## Stage 0

* Install locale packages
* Configure timezone
* Update OS
* Install EPEL
* Install Git
* Disable SELinux
* Reboot

## Stage 1

### Express

Database + Web + Telephony

### Database Master

### Database Slave

### Web

### Telephony

### Archive

### Custom

## Assets

### MariaDB

* cache-buffers.cnf
* general.cnf
* innodb.cnf
* replication.cnf

### Apache

* audiostore.conf
* dynportal.conf
* dynportal-ssl.conf
* viciarchive.conf
* vicirecord.conf

### Firewall

* VB-firewall.pl
* ipset-geoblock
* vicibox-geoblock.conf

### Dynportal

* valid8.php
* css
* images
* inc
