{% from "nova/map.jinja" import controller with context %}

{%- if controller.get('enabled') %}

{%- if grains.os_family == 'Debian' %}
debconf-set-prerequisite:
    pkg.installed:
      - name: debconf-utils
      - require_in:
        - debconf: nova_consoleproxy_debconf

nova_consoleproxy_debconf:
  debconf.set:
  - name: nova-consoleproxy
  - data:
      'nova-consoleproxy/daemon_type':
        type: 'string'
        value: 'novnc'
  - require_in:
    - pkg: nova_controller_packages
{%- endif %}

nova_controller_packages:
  pkg.installed:
  - names: {{ controller.pkgs }}

{%- if controller.message_queue.get('ssl',{}).get('enabled',False)  %}
rabbitmq_ca_nova_controller:
{%- if controller.message_queue.ssl.cacert is defined %}
  file.managed:
    - name: {{ controller.message_queue.ssl.cacert_file }}
    - contents_pillar: nova:controller:message_queue:ssl:cacert
    - mode: 0444
    - makedirs: true
{%- else %}
  file.exists:
   - name: {{ controller.message_queue.ssl.get('cacert_file', controller.cacert_file) }}
{%- endif %}
{%- endif %}

{%- if not salt['user.info']('nova') %}
user_nova:
  user.present:
  - name: nova
  - home: /var/lib/nova
  - shell: /bin/false
  {# note: nova uid/gid values would not be evaluated after user is created. #}
  - uid: {{ controller.get('nova_uid', 303) }}
  - gid: {{ controller.get('nova_gid', 303) }}
  - system: True
  - require_in:
    - pkg: nova_controller_packages
{%- if controller.version not in ["juno", "kilo", "liberty", "mitaka", "newton"] %}
    - pkg: nova_placement_package
{%- endif %}

group_nova:
  group.present:
    - name: nova
    {# note: nova gid value would not be evaluated after user is created. #}
    - gid: {{ controller.get('nova_gid', 303) }}
    - system: True
    - require_in:
      - user: user_nova
{%- endif %}

{%- if controller.get('networking', 'default') == "contrail" and controller.version == "juno" %}

contrail_nova_packages:
  pkg.installed:
  - names:
    - contrail-nova-driver
    - contrail-nova-networkapi

{%- endif %}

/etc/nova/nova.conf:
  file.managed:
  - source: salt://nova/files/{{ controller.version }}/nova-controller.conf.{{ grains.os_family }}
  - template: jinja
  - require:
    - pkg: nova_controller_packages

/etc/nova/api-paste.ini:
  file.managed:
  - source: salt://nova/files/{{ controller.version }}/api-paste.ini.{{ grains.os_family }}
  - template: jinja
  - require:
    - pkg: nova_controller_packages

{% for service_name in controller.services %}
{{ service_name }}_default:
  file.managed:
    - name: /etc/default/{{ service_name }}
    - source: salt://nova/files/default
    - template: jinja
    - require:
      - pkg: nova_controller_packages
    - defaults:
        service_name: {{ service_name }}
        values: {{ controller }}
    - require:
      - pkg: nova_controller_packages
    - watch_in:
      - service: nova_controller_services
{% endfor %}

{% if controller.logging.log_appender %}

{%- if controller.logging.log_handlers.get('fluentd').get('enabled', False) %}
nova_controller_fluentd_logger_package:
  pkg.installed:
    - name: python-fluent-logger
{%- endif %}

nova_general_logging_conf:
  file.managed:
    - name: /etc/nova/logging.conf
    - source: salt://nova/files/logging.conf
    - template: jinja
    - user: nova
    - group: nova
    - require:
      - pkg: nova_controller_packages
{%- if controller.logging.log_handlers.get('fluentd').get('enabled', False) %}
      - pkg: nova_controller_fluentd_logger_package
{%- endif %}
    - defaults:
        service_name: nova
        values: {{ controller }}
    - watch_in:
      - service: nova_controller_services

/var/log/nova/nova.log:
  file.managed:
    - user: nova
    - group: nova
    - watch_in:
      - service: nova_controller_services
{%- if controller.version not in ["juno", "kilo", "liberty", "mitaka", "newton"] %}
      - service: nova_apache_restart
{%- endif %}

{% for service_name in controller.services %}

{{ service_name }}_logging_conf:
  file.managed:
    - name: /etc/nova/logging/logging-{{ service_name }}.conf
    - source: salt://nova/files/logging.conf
    - template: jinja
    - user: nova
    - group: nova
    - require:
      - pkg: nova_controller_packages
{%- if controller.logging.log_handlers.get('fluentd').get('enabled', False) %}
      - pkg: nova_controller_fluentd_logger_package
{%- endif %}
    - makedirs: True
    - defaults:
        service_name: {{ service_name }}
        values: {{ controller }}
    - watch_in:
      - service: nova_controller_services
{%- if controller.version not in ["juno", "kilo", "liberty", "mitaka", "newton"] %}
      - service: nova_apache_restart
{%- endif %}

{% endfor %}
{% endif %}

{% if controller.get('policy', {}) and controller.version not in ['liberty', 'mitaka', 'newton'] %}
{# nova no longer ships with a default policy.json #}

/etc/nova/policy.json:
  file.managed:
    - contents: '{}'
    - replace: False
    - user: nova
    - group: nova
    - require:
      - pkg: nova_controller_packages

{% endif %}

{%- for name, rule in controller.get('policy', {}).iteritems() %}

{%- if rule != None %}
rule_{{ name }}_present:
  keystone_policy.rule_present:
  - path: /etc/nova/policy.json
  - name: {{ name }}
  - rule: {{ rule }}
  - require:
    - pkg: nova_controller_packages
    {% if controller.version not in ['liberty', 'mitaka', 'newton'] %}
    - file: /etc/nova/policy.json
    {% endif%}

{%- else %}

rule_{{ name }}_absent:
  keystone_policy.rule_absent:
  - path: /etc/nova/policy.json
  - name: {{ name }}
  - require:
    - pkg: nova_controller_packages
    {% if controller.version not in ['liberty', 'mitaka', 'newton'] %}
    - file: /etc/nova/policy.json
    {% endif%}

{%- endif %}

{%- endfor %}

{%- if controller.version not in ["juno", "kilo", "liberty", "mitaka", "newton"] %}

{#- the following api_db sync --version 20 happens only if the current api_db version is < 20 #}

nova_controller_api_db_sync_version_20:
  novang.api_db_version_present:
  - version: "20"
  {%- if grains.get('noservices') %}
  - onlyif: /bin/false
  {%- endif %}
  - require:
    - file: /etc/nova/nova.conf

{#- the following db sync --version 334 happens only if the current db version is < 334 #}

nova_controller_db_sync_version_334:
  novang.db_version_present:
  - version: "334"
  {%- if grains.get('noservices') %}
  - onlyif: /bin/false
  {%- endif %}
  - require:
    - file: /etc/nova/nova.conf

{#- the following db online_data_migrations executes only if the current db version == 334 && api_db version == 20 #}

online_data_migrations_for_apidb20_and_db334:
  novang.online_data_migrations_present:
  - api_db_version: "20"
  - db_version: "334"
  {%- if grains.get('noservices') %}
  - onlyif: /bin/false
  {%- endif %}
  - require:
    - novang: nova_controller_api_db_sync_version_20
    - novang: nova_controller_db_sync_version_334

nova_controller_map_cell0:
  cmd.run:
  - name: nova-manage cell_v2 map_cell0
  {%- if grains.get('noservices') %}
  - onlyif: /bin/false
  {%- endif %}
  - require:
    - cmd: nova_controller_syncdb

nova_cell1_create:
  cmd.run:
  - name: nova-manage cell_v2 create_cell --name=cell1
  {%- if grains.get('noservices') %}
  - onlyif: /bin/false
  {%- endif %}
  - unless: 'nova-manage cell_v2 list_cells | grep cell1'
  - require:
    - cmd: nova_controller_syncdb

{%- if controller.get('update_cells') %}

nova_update_cell0:
  novang.update_cell:
  - name: "cell0"
  - db_name: {{ controller.database.name }}_cell0
  - db_engine: {{ controller.database.engine }}
  - db_password: {{ controller.database.password }}
  - db_user: {{ controller.database.user }}
  - db_address: {{ controller.database.host }}
  {%- if grains.get('noservices') %}
  - onlyif: /bin/false
  {%- endif %}

{%- set rabbit_port = controller.message_queue.get('port', 5671 if controller.message_queue.get('ssl',{}).get('enabled', False) else 5672) %}

nova_update_cell1:
  novang.update_cell:
  - name: "cell1"
  - db_name: {{ controller.database.name }}
{%- if controller.message_queue.members is defined %}
  - transport_url = rabbit://{% for member in controller.message_queue.members -%}
                             {{ controller.message_queue.user }}:{{ controller.message_queue.password }}@{{ member.host }}:{{ member.get('port', rabbit_port) }}
                             {%- if not loop.last -%},{%- endif -%}
                         {%- endfor -%}
                             /{{ controller.message_queue.virtual_host }}
{%- else %}
  - transport_url: rabbit://{{ controller.message_queue.user }}:{{ controller.message_queue.password }}@{{ controller.message_queue.host }}:{{ rabbit_port}}/{{ controller.message_queue.virtual_host }}
{%- endif %}
  - db_engine: {{ controller.database.engine }}
  - db_password: {{ controller.database.password }}
  - db_user: {{ controller.database.user }}
  - db_address: {{ controller.database.host }}
  {%- if grains.get('noservices') %}
  - onlyif: /bin/false
  {%- endif %}

{%- endif %}

nova_placement_service_mask:
  file.symlink:
   - name: /etc/systemd/system/nova-placement-api.service
   - target: /dev/null

nova_placement_package:
  pkg.installed:
  - name: nova-placement-api
  - require:
    - file: nova_placement_service_mask

{#- Creation of sites using templates is deprecated, sites should be generated by apache pillar, and enabled by barbican formula #}
{%- if pillar.get('apache', {}).get('server', {}).get('site', {}).nova_placement is not defined %}

nova_placement_apache_conf_file:
  file.managed:
  - name: /etc/apache2/sites-available/nova-placement-api.conf
  - source: salt://nova/files/{{ controller.version }}/nova-placement-api.conf
  - template: jinja
  - require:
    - pkg: nova_controller_packages
    - pkg: nova_placement_package

placement_config:
  apache_site.enabled:
    - name: nova-placement-api
    - require:
      - nova_placement_apache_conf_file

{%- else %}

include:
 - apache

nova_cleanup_configs:
  file.absent:
    - names:
      - '/etc/apache2/sites-available/nova-placement-api.conf'
      - '/etc/apache2/sites-enabled/nova-placement-api.conf'

nova_placement_apache_conf_file:
  file.exists:
  - name: /etc/apache2/sites-available/wsgi_nova_placement.conf
  - require:
    - pkg: nova_placement_package
    - nova_cleanup_configs

placement_config:
  apache_site.enabled:
    - name: wsgi_nova_placement
    - require:
      - nova_placement_apache_conf_file

{%- endif %}

nova_controller_discover_hosts:
  cmd.run:
  - name: nova-manage cell_v2 discover_hosts
  {%- if grains.get('noservices') %}
  - onlyif: /bin/false
  {%- endif %}
  - require:
    - cmd: nova_controller_map_cell0
    - cmd: nova_cell1_create
    - cmd: nova_controller_syncdb

nova_controller_map_instances:
  novang.map_instances:
  - name: 'cell1'
  {%- if grains.get('noservices') %}
  - onlyif: /bin/false
  {%- endif %}
  - require:
    - cmd: nova_controller_discover_hosts
    - pkg: nova_controller_packages

{%- endif %}

{%- if controller.version not in ["juno", "kilo", "liberty"] %}
nova_controller_sync_apidb:
  cmd.run:
  - name: nova-manage api_db sync
  {%- if grains.get('noservices') %}
  - onlyif: /bin/false
  {%- endif %}
  - require:
    - file: /etc/nova/nova.conf

{%- endif %}

nova_controller_syncdb:
  cmd.run:
  - names:
    - nova-manage db sync
  {%- if grains.get('noservices') %}
  - onlyif: /bin/false
  {%- endif %}
  - require:
    - file: /etc/nova/nova.conf

{%- if controller.version not in ["juno", "kilo", "liberty"] %}

nova_controller_online_data_migrations:
  cmd.run:
  - name: nova-manage db online_data_migrations
  {%- if grains.get('noservices') %}
  - onlyif: /bin/false
  {%- endif %}
  - require:
    - cmd: nova_controller_syncdb

{%- endif %}

{%- if controller.version not in ["juno", "kilo", "liberty", "mitaka", "newton"] %}

nova_apache_restart:
  service.running:
  - enable: true
  - name: apache2
  {%- if grains.get('noservices') %}
  - onlyif: /bin/false
  {%- endif %}
  - require:
    - cmd: nova_controller_syncdb
  - watch:
    - file: /etc/nova/nova.conf
    - file: /etc/nova/api-paste.ini
    - nova_placement_apache_conf_file
    {%- if controller.database.get('ssl',{}).get('enabled',False)  %}
    - file: mysql_ca_nova_controller
    {% endif %}

{%- endif %}

nova_controller_services:
  service.running:
  - enable: true
  - names: {{ controller.services }}
  {%- if grains.get('noservices') %}
  - onlyif: /bin/false
  {%- endif %}
  - require:
    - cmd: nova_controller_syncdb
  - watch:
    - file: /etc/nova/nova.conf
    - file: /etc/nova/api-paste.ini
    {%- if controller.message_queue.get('ssl',{}).get('enabled',False) %}
    - file: rabbitmq_ca_nova_controller
    {%- endif %}
    {%- if controller.database.get('ssl',{}).get('enabled',False)  %}
    - file: mysql_ca_nova_controller
    {% endif %}

{%- if grains.get('virtual_subtype', None) == "Docker" %}

nova_entrypoint:
  file.managed:
  - name: /entrypoint.sh
  - template: jinja
  - source: salt://nova/files/entrypoint.sh
  - mode: 755

{%- endif %}

{%- if controller.database.get('ssl',{}).get('enabled',False)  %}
mysql_ca_nova_controller:
{%- if controller.database.ssl.cacert is defined %}
  file.managed:
    - name: {{ controller.database.ssl.cacert_file }}
    - contents_pillar: nova:controller:database:ssl:cacert
    - mode: 0444
    - makedirs: true
    - require_in:
      - file: /etc/nova/nova.conf
{%- else %}
  file.exists:
   - name: {{ controller.database.ssl.get('cacert_file', controller.cacert_file) }}
   - require_in:
     - file: /etc/nova/nova.conf
{%- endif %}
{%- endif %}

{%- endif %}
