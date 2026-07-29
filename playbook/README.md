# Домашнее задание к занятию 1 «Введение в Ansible»

## Основная часть

1. Значение some_fact при запуске на test.yml: 12
2. Файл с переменными: group_vars/all/examp.yml — изменено на "all default fact"
3. Окружение: Docker-контейнеры centos:7 и ubuntu:latest
4. Значения some_fact на prod.yml: centos7=el, ubuntu=deb
5-6. После изменения: centos7="el default fact", ubuntu="deb default fact"
7-8. Файлы group_vars/deb и group_vars/el зашифрованы ansible-vault с паролем netology. Запуск с --ask-vault-pass успешен.
9. Плагин для control node: ansible.builtin.local
10-11. Добавлена группа local с localhost (ansible_connection: local). Результат: centos7="el default fact", ubuntu="deb default fact", localhost="all default fact"
