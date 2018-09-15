# lmapi-scripts

* WM/LMAPI.pm
  * simple API wrapper to deal with LM machinery, like JSON and rate-limiting.  Expects API credentials in a YAML file in ~/.lmapi formatted as:

 ```yaml
 ---
 companies:
    COMPANY1:
        access_id: 'ACCESS_ID'
        access_key: 'ACCESS_KEY'
    COMPANY2:
        access_id: 'ACCESS_ID'
        access_key: 'ACCESS_KEY'
    COMPANY3:
        access_id: 'ACCESS_ID'
        access_key: 'ACCESS_KEY'
 ```

* lm-get-configs
  * collect ConfigSource files from all devices within a portal

* run-lm-get-configs
  * wrapper for lm-get-configs, uses git after refresh to update repository
