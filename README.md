# cdeploy
conventional deployment to AWS lambda

# Requirements
```
gem install aws-sdk
gem install rubyzip
gem install unindent

and 

%> aws configure
```

# Usage

```
1. deployフォルダに移動します
   cd deploy

2. deploy.rb を実行します。
   1) ruby deploy.rb
     または
   2) ruby deploy.rb -function=ファンクション名
     例) ruby deploy.rb -function=<function_folder_name>
     または
   3) ruby deploy.rb -feature=フィーチャー名
     例) ruby deploy.rb -feature=<feature_folder_name>
   説明
     1) プロジェクト フォルダ配下のすべてのファンクションをデプロイ。
     2) -functionで指定したファンクションのみデプロイ
     3) -featureで指定したフォルダの下のみデプロイ
 
 - その他のオプション
   -test => ステージング環境にデプロイします。(default: ソウルリージョン)
     s3をデプロイする場合、バケット名は、staging- というプレフィクスがつきます。
     各ファンクションに適用されるロールは <project_folder_name>-staging-role になります。
     ファンクションは全てデフォルトサブネットに所属します。
   -region=<<region>>
     デプロイするリージョンを指定します。
```

# lambda デプロイスクリプトの構成
```
 deploy
   +-- deliver => すべてのlambdaファンクションに配布するライブラリを格納(以下はデフォルトでインプリメントできるライブラリ)
     +-- mysqldb
     +-- dbconf
     +-- digest
     +-- s3_glue
     +-- sns_glue
   +-- aws_adapter.rb => aws-sdk 接続用のアダプタ
   +-- deploy.rb => デプロイスクリプト
   +-- zip_generator.rb => lambdaフォルダの圧縮スクリプト
   +-- .ignore.json => デプロイしないlambdaファンクションのリスト
   +-- .policy.json => すべてのlambdaファンクションに適用するIAMポリシーのリスト
   +-- policy_doc.rb => lambda に適用する IAM ポリシーを定義したライブラリ
   +-- .resource.json => 外部リソース(SQS、dynamoDBなど)の設定を記述
   +-- .database.json => 本番とステージング環境のデータベース接続情報を記述
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
   "dynamodb": ["my_dynamo_db"],
   "sqs": ["my_queue"],
   "s3": [{"name":"mybucket", "is_event_source": false}]
   "s3": [{"name":"mybucket"}] => "↑と同じ"
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

 # .vpc.json
 lambda ファンクションが所属するvpcサブネットのidとセキュリティグループidを記述
 例)
 ```
 {
   "subnet_ids": ["subnet-xxxxxx"],
   "security_group_ids": ["sg-xxxxxxxx"]
 }
 ```

  deploy フォルダ

 # .ignore.json
 デプロイしないfeatureフォルダを列挙
 例)
 ```
 [
   "deploy",
   "test"
 ]
 ```

 # .policy.json
 各ファンクションに共通で適用するポリシーARNを列挙
 例)
 ```
 [
   "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
 ]
 ```

 # .resource.json
 直接連携しない外部リソースの設定を記述（2016.10.27時点ではSQLのDelayのみ対応）
 例)
 ```
 {
   "sqs": {
       "MyQueue": { "delay": "30" },
       "MyQueue2": { "delay": "0" }
   }
 }
 ```

