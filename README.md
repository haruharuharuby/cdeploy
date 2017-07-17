# cdeploy
conventional deployment to AWS lambda.
This project deploys your python code to AWS lambda with libraries and other resources.

for easy to manage lambda and other resources.

# Requirements
```
gem install aws-sdk
gem install rubyzip
gem install unindent
```
Then, set the aws credentials

```
%> aws configure
```

# Construct project structure
```
 <Folder:: name of project>
   +-- deploy(this folder)
   +-- <Folder:: feature 1>
     +-- <Folder:: name of lambda function A>
     +-- <Folder:: name of lambda function B>
             :
     +-- <Folder:: name of lambda function N>
   +-- <Folder:: feature 2>
     +-- <Folder:: name of lambda function X>
     +-- <Folder:: name of lambda function Y>
```

# Usage 

1. move to deploy folder
   cd deploy

2. run deploy.rb
  **There are 3 deploy options**
   1) ruby deploy.rb
     or 
   2) ruby deploy.rb -function=<name of function's folder>
     ex) ruby deploy.rb -function=my_function
     or
   3) ruby deploy.rb -feature=<name of feature's folder>
     ex) ruby deploy.rb -feature=my_feature
     
   **description**
     1) deploy all features and functions
     2) deploy specific function
     3) deploy specific feature( deploy all functions under specified feature)
     
 **other options**
   -test(work in progress) => deploy for testing.(default: seoul region)
     It is added 'staging-' prefix to bucket name if you link to s3.
     It is deployed the IAM role named **<project_folder_name>-staging-role** if you deploy with -test option
     All functions belongs to default subnet.
   -region=<<region>>
     specify region to deploying

# Cunstructure in the deploy
```
 deploy
   +-- deliver => You can import libraries as follows
     +-- bcrypt
     +-- certifi
     +-- chardet
     +-- Crypto
     +-- digest
     +-- idna
     +-- jinja2
     +-- markupsafe
     +-- mysqldb
     +-- packaging
     +-- pymssql
     +-- requests
     +-- s3_glue
     +-- sns_glue
     +-- urllib3
   +-- aws_adapter.rb => adapter of aws-sdk
   +-- deploy.rb => main deploy script
   +-- zip_generator.rb => compression script
   +-- .ignore.json => list of folders which ignoring deploy
   +-- .policy.json => policies that attached all lambda function
   +-- policy_doc.rb => policy templates
   +-- **(Work in progress)**.resource.json => list of additional resources
   +-- **(deplicated)**.database.json
```


# 各ファンクションフォルダ
 ```
   +-- 外部ライブラリなど
   +-- lambda_function.py
   +-- .import.json deploy/deliver フォルダからインポートするライブラリのリスト
   +-- .policy.json => ファンンクション固有に適用するポリシーのリスト
   +-- .vpc.json => lambdaをVPCに所属させる場合の subnet_id と security_group_id のリスト
                    ファイルがなければVPCには所属しない。
                    本番環境にのみ適用される
   +-- .lambda.json => lambdaファンクションの設定を記述。
 ```


# プロジェクトフォルダの構成
```
 プロジェクト名
   +-- 機能1
     +-- function A
     +-- function B
             :
     +-- function N
   +-- 機能2
     +-- function X
     +-- function Y
             :
 ```
 
 デプロイしたときのlambdaファンクション名は、"プロジェクト名-機能名-function名"

# デプロイスクリプトの動作
 上述したフォルダ構成において、function フォルダを "プロジェクト名-機能名-function名" でデプロイします。
 lambdaファンクションと同名のroleを作成しアタッチします。
 roleには以下の３つのIAMポリシーをアタッチします。
   1) lambdaファンクションと同名のポリシー
   2) deploy/common_policy.json
   3) 各functionフォルダのpolicy.json
 連携するSNSトピックへのcreate_topic、publish 権限を1)に設定する必要があります。
 SNSトピックとroleとポリシーは事前に設定する必要があります。

 glueライブラリ
 .import.json に sns_glue, または、s3_glue を記述すると、sns_glue.py, s3_glue.py
 がインポートされますが、policy.json に連携先のバケット または トピックがない場合は
 エラーになります。 バケット名がまだ未定 などの場合は、.import.json にglueライブラリを
 記述しないでください。

# 各jsonファイルの形式
 各ラムダファンクションフォルダ
 ## .import.json
 deploy/deliver以下のフォルダ名を列挙。
 例)
 ```
 [
   "mysqldb",
   "dbconf"
 ]
 ```

 ## .policy.json
 連携するawsサービスをキー、各サービスの識別名のリストをvalue。
 dynamodbはテーブル名、sqsはキュー名、snsはトピック名、s3はバケット名
 s3のみ、リストにはオブジェクトを入れる必要があるので注意。
 s3["name"] = バケット名
 s3["is_event_source"] は、s3バケットをlambdaのイベントソースとして使う場合は true,そうでない場合は false
 記述がなければ、false です。

 例)
 ```
 {
   "dynamodb": ["conversion_cancel_logs"],
   "sqs": ["ConversionQueue"],
   "s3": [{"name":"web.hoge.click", "is_event_source": false}]
   "s3": [{"name":"web.hoge.click"}] => "↑と同じ"
 }
 ```

 ## .lambda.json
 lambda ファンクションの使用するメモリ、タイムアウト、環境変数を記述
 なければ、デフォルト値(128MB、3秒)です。
 例)
 ```
 {
   "timeout": "90",
   "memory": "256"
   "env": {
     "DATABASE_HOST_MYSQL": "XXXXX",
     "DATABASE_PORT_MYSQL": "XXXXX",
     "DATABASE_USER_MYSQL": "XXXXX",
     "DATABASE_PASSWORD_MYSQL": "XXXXX",
     "DATABASE_NAME_MYSQL": "XXXXX"
    }
 }
 ```

 ## .vpc.json
 lambda ファンクションが所属するvpcサブネットのidとセキュリティグループidを記述
 例)
 ```
 {
   "subnet_ids": ["subnet-2538dd7d"],
   "security_group_ids": ["sg-98002bfc"]
 }
 ```

  deploy フォルダ

 ## .ignore.json
 デプロイしないfeatureフォルダを列挙
 例)
 ```
 [
   "deploy",
   "test"
 ]
 ```

 ## .policy.json
 各ファンクションに共通で適用するポリシーARNを列挙
 例)
 ```
 [
   "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
 ]
 ```

 ## .resource.json
 直接連携しない外部リソースの設定を記述（2016.10.27時点ではSQLのDelayのみ対応）
 例)
 ```
 {
   "sqs": {
       "ConversionQueue": { "delay": "30" },
       "ConversionKickbackRetryQueue": { "delay": "0" }
   }
 }
 ```

