#!/bin/bash

################
# CONF GÉNÉRAL #
################

#Empêche l'expansion du joker
set -f
#COULEURS
RED='\e[0;31m'
GREEN='\e[0;32m'
NC='\e[0m'
ARROW="${GREEN}==>${NC}"

#FONCTIONS
timestamp() { echo $(date +"%s"); }
elapsed() {
	ELAPSED=$(($(timestamp)-$1))
	echo "\n=> Temps écoulé : " `echo ${ELAPSED} | awk '{printf("%01d heures, %01d minutes et %01d secondes", ($1/3600), ($1%3600/60),($1%60))}'`
}

#BINAIRES
SCP=/usr/bin/scp
RSYNC=/usr/bin/rsync
MYSQLDUMP=/usr/bin/mysqldump

#VÉRIFICATION DE L'UTILISATEUR
if [[ $EUID -eq 0 ]]; then
   echo "Ce script ne doit pas être lancé en tant que root"
   exit 1
fi

##############
# CONF LOCAL #
##############

######### FICHIERS-CONF
if [[ -f /home/cua/rsync-exclusions.txt ]]; then
    RSYNC_EXCLUDE=/home/cua/rsync-exclusions.txt
fi
read -p "Entrez le répertoire local à copier SANS SLASH DE FIN (ex: /home/cua/public_html/monsite.fr) : " LOCAL_DIR

######## FICHIERS-TESTS
if [[ -d ${LOCAL_DIR} ]]; then
	printf "\nLe répertoire local existe !\n"
else
	printf "\nLe répertoire local n'exite pas.\n"
    exit 1
fi

######### SGBD-CONF
printf "\n\n***********************\n ENVIRONNEMENT LOCAL :\n***********************\n\n"
read -p "Entrez l'utilisateur de la base de données à migrer : " LOCAL_DB_USER
read -p "Entrez le mot de passe de cet utilisateur : " LOCAL_DB_PASS
read -p "Entrez le nom de la base de données à migrer : " LOCAL_DB_NAME

########## SGBD-TESTS
if mysql -u ${LOCAL_DB_USER} -p${LOCAL_DB_PASS} ${LOCAL_DB_NAME} -e exit 2>/dev/null; then
    printf "${ARROW} Wouhou, connexion à la base locale réussie !\n\n"
else
    printf "${ARROW} Connexion à la base locale échouée. Vérifiez l'identifiant, le mot de passe et le nom de la base.\n"
    exit
fi

################
# CONF DISTANT #
################

printf "\n*************************\n ENVIRONNEMENT DISTANT :\n*************************\n\n"
read -p "Entrez l'IP ou un nom de domaine pointant sur le serveur cible : " REMOTE_IP
read -p "Entrez le nom de l'utilisateur SSH sur le serveur distant (dev/prod) : " REMOTE_USER

########## FICHIERS-CONF
read -p "Entrez le répertoire où sera copié le nouveau site sur le serveur distant (ex: /home/dev) : " REMOTE_DIR

########## SGBD-CONF
printf "\n"
read -p "Entrez le nom du super-utilisateur du SGBD distant : " REMOTE_ROOT_USER
read -p "Ainsi que son mot de passe : " REMOTE_ROOT_PASS
read -p "Entrez le nom de l'utilisateur cible sur le serveur distant : " REMOTE_DB_USER
read -p "Ainsi que son mot de passe : " REMOTE_DB_PASS
read -p "Entrez le nom de la base de données cible : " REMOTE_DB_NAME

######### SGBD-TESTS
MYSQL_CHECK_USER="SELECT * FROM mysql.user WHERE User='${REMOTE_DB_USER}';"
REMOTE_USER_EXISTS=`ssh ${REMOTE_USER}@${REMOTE_IP} mysql -u ${REMOTE_ROOT_USER} -p${REMOTE_ROOT_PASS} -e \"${MYSQL_CHECK_USER}\"`

MYSQL_CHECK_DB="SHOW DATABASES LIKE '${REMOTE_DB_NAME}';"
REMOTE_DB_EXISTS=`ssh ${REMOTE_USER}@${REMOTE_IP} mysql -u ${REMOTE_ROOT_USER} -p${REMOTE_ROOT_PASS} -e \"${MYSQL_CHECK_DB}\"`

MYSQL_DROP_DB="DROP DATABASE ${REMOTE_DB_NAME};"
MYSQL_CREATE_DB="CREATE DATABASE ${REMOTE_DB_NAME};"
MYSQL_CREATE_USER="CREATE USER ${REMOTE_DB_USER}@'localhost';"
MYSQL_USER_GRANT="GRANT ALL ON ${REMOTE_DB_NAME}.* TO ${REMOTE_DB_USER}@'localhost' IDENTIFIED BY '${REMOTE_DB_PASS}';"

if [[ -n ${REMOTE_USER_EXISTS} ]]; then
    printf "\nL'utilisateur de la BDD existe déjà. Tentative de connexion…\n"
    if ssh ${REMOTE_USER}@${REMOTE_IP} mysql -u ${REMOTE_DB_USER} -p${REMOTE_DB_PASS} -e "exit;"; then
        printf "${ARROW} Connexion réussie.\n"
    else
        printf "${ARROW} Connexion échouée. Le mot de passe est probablement erronné."
        exit
    fi
else
    read -p "L'utilisateur de la BDD n'existe pas. Voulez-vous le créer ? (o/N)" -n 1 -r
    if [[ $REPLY =~ ^[Oo]$ ]]
    then
        printf "\nCréation de l'utilisateur…\n"
        ssh ${REMOTE_USER}@${REMOTE_IP} mysql -u ${REMOTE_ROOT_USER} -p${REMOTE_ROOT_PASS} -e \"${MYSQL_CREATE_USER}\"
    else
        printf "On arrête là.\n"
        exit
    fi
fi

#Ici, on sait que l'utilisateur existe mais on ne sait pas si la base existe ou s'il a les droits dessus le cas échéant
if [[ -n ${REMOTE_DB_EXISTS} ]]; then
    printf "\nLa base ${REMOTE_DB_NAME} existe déjà\n"
    if [[ -n `ssh ${REMOTE_USER}@${REMOTE_IP} mysqlshow -u ${REMOTE_ROOT_USER} -p${REMOTE_ROOT_PASS} ${REMOTE_DB_NAME}` ]]; then
        printf "…et elle n'est pas vide !\n"
        read -p "Voulez-vous supprimer toutes ses tables ? (o/N)" -n 1 -r
        if [[ $REPLY =~ ^[Oo]$ ]]
        then
            ssh ${REMOTE_USER}@${REMOTE_IP} mysql -u ${REMOTE_ROOT_USER} -p${REMOTE_ROOT_PASS} -e \"${MYSQL_DROP_DATABASE}\"
            ssh ${REMOTE_USER}@${REMOTE_IP} mysql -u ${REMOTE_ROOT_USER} -p${REMOTE_ROOT_PASS} -e \"${MYSQL_CREATE_DATABASE}\"
        else
            printf "On arrête là.\n"
            exit
        fi
    else
        printf "…et elle est vide.\n"
    fi
    printf "Attribution des privilèges (au cas où)…\n"
    ssh ${REMOTE_USER}@${REMOTE_IP} mysql -u ${REMOTE_ROOT_USER} -p${REMOTE_ROOT_PASS} -e \"${MYSQL_USER_GRANT}\"
else
    read -p "La BDD n'existe pas. Voulez-vous la créer ? (o/N)" -n 1 -r
    if [[ $REPLY =~ ^[Oo]$ ]]
    then
        printf "\nCréation de la base de données…\n"
        ssh ${REMOTE_USER}@${REMOTE_IP} mysql -u ${REMOTE_ROOT_USER} -p${REMOTE_ROOT_PASS} -e \"${MYSQL_CREATE_DB}\"
        printf "Attribution des privilèges…\n"
        ssh ${REMOTE_USER}@${REMOTE_IP} mysql -u ${REMOTE_ROOT_USER} -p${REMOTE_ROOT_PASS} -e \"${MYSQL_USER_GRANT}\"
    else
        printf "On arrête là.\n"
        exit
    fi
fi

printf "\nOn teste la connexion à la base de données avec l'utilisateur…\n"
if ssh ${REMOTE_USER}@${REMOTE_IP} mysql -u ${REMOTE_DB_USER} -p${REMOTE_DB_PASS} ${REMOTE_DB_NAME} -e "exit;"; then
    printf "${ARROW} La connexion fonctionne !\n\n"
else
    printf "${ARROW} La connexion ne fonctionne pas. #FAIL\n\n"
    exit
fi

######### RECHERCHER & REMPLACER WORDPRESS
read -p "Voulez-vous effectuer un rechercher&remplacer dans la base de données ? (o/N)" -n 1 -r
if [[ $REPLY =~ ^[Oo]$ ]]
then
    echo
    read -p "Quelle chaîne voulez-vous rechercher (ex: dev/monsite.fr/) ? " -r SEARCH_RAW
    read -p "Par quelle chaîne voulez-vous la remplacer (ex: monsite.fr/) ? " -r REPLACE_RAW
fi

printf "\nOK. Paré au décollage.\n"

################
# ACTUAL STUFF #
################

printf "\n${ARROW} Copie des fichiers sur le serveur distant...\n\n"
CPBEGIN=$(timestamp)
${RSYNC} --exclude-from "${RSYNC_EXCLUDE}" --stats --info=progress2 -azh ${LOCAL_DIR} ${REMOTE_USER}@${REMOTE_IP}:${REMOTE_DIR}
echo -e $(elapsed $CPBEGIN)

echo -e "\n${ARROW} Copie de la base de données sur le serveur distant...\n"
CPBEGIN=$(timestamp)
if [[ -z ${SEARCH_RAW} ]] || [[ -z ${REPLACE_RAW} ]]; then
    printf "\nCopie sans rechercher&remplacer…\n"
    ${MYSQLDUMP} -u ${LOCAL_DB_USER} -p${LOCAL_DB_PASS} ${LOCAL_DB_NAME} | ssh ${REMOTE_USER}@${REMOTE_IP} mysql -u ${REMOTE_DB_USER} -p${REMOTE_DB_PASS} ${REMOTE_DB_NAME}
else
    printf "\nCopie avec rechercher&remplacer…\n"
    ${MYSQLDUMP} -u ${LOCAL_DB_USER} -p${LOCAL_DB_PASS} ${LOCAL_DB_NAME} | sed 's|'${SEARCH_RAW}'|'${REPLACE_RAW}'|g' | ssh ${REMOTE_USER}@${REMOTE_IP} mysql -u ${REMOTE_DB_USER} -p${REMOTE_DB_PASS} ${REMOTE_DB_NAME}
fi

echo -e $(elapsed $CPBEGIN)
