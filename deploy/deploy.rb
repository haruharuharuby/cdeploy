#!/bin/ruby
require 'date'
require 'json'
require 'aws-sdk'
require 'fileutils'
require 'unindent'
require './aws_adapter.rb'
require './zip_generator.rb'
require './policy_doc.rb'


class ConventionallyDeployment
  include PolicyDoc
  attr_reader :project, :region

  def initialize(region="ap-northeast-2", test=true)
    @region = region
    @test = test
    @project = File.basename(File.expand_path("..", Dir.pwd))
    @aws = AwsAdapter.new(region=region)
    puts "[STATE::DEPLOY::REGION] #{region}"
  end

  # function = "feature-action"
  def deploy_single_function(function)
    puts ""
    puts "[OPERATION::DEPLOY_SINGLE_FUNCTION::Start]"

    element = function.split("-")
    deploy_function(element[0],element[1])

    puts "[OPERATION::DEPLOY_SINGLE_FUNCTION::Finished]"
    puts ""
  end

  def deploy_feature(feature)
    Dir.entries("../#{feature}")[2..-1].map{|action|
      deploy_function(feature, action) if File.ftype("../#{feature}/#{action}") == 'directory'
    }
  end

  # This function is whole functions and arround resources.
  def deploy_all_functions()
    puts ""
    puts "[OPERATION::DEPLOY_ALL::Start]"

    ignores = {}
    open(".ignore.json"){|f| ignores = JSON.load(f)}
    features = Dir.entries("..")[2..-1].select{|entry|
      !ignores.include?(entry)
    }

    features.map {|feature| deploy_feature(feature)}

    puts "[OPERATION::DEPLOY_ALL::Finished]"
    puts ""
  end

  private

    def deploy_function(feature, action)
      puts ""
      puts "[OPERATION::DEPLOY_FUNCTION::Start] #{feature}-#{action}"

      name = build_name feature, action
      role = create_role name
      attach_policy name
      deploy_lambda_function name, role
      link_resource name

      puts "[OPERATION::DEPLOY_FUNCTION::Finished] #{feature}-#{action}"
      puts ""
    end

    def create_role(name="")
      iam = @aws.iam

      if test?
        role = iam.role "adamas-staging-role"
        puts "[STATE::IAM] deployed staging role."
        return role
      end

      role = iam.role name
      begin
        role.arn
        puts "[STATE::IAM] Role deployed (already existed) #{role.arn}"
      rescue
        role = iam.create_role({role_name: name, assume_role_policy_document: assume_role_policy_doc.to_json })
        puts "[STATE::IAM] Role deployed (created) #{role.arn}"
      end
      role
    end


    def deploy_lambda_function(name, role)
      path = to_path(name)
      zippath = "#{path}/app.zip"

      copy_imports_libs path

      File.delete zippath if File.exist? zippath
      ZipGenerator.new(path, zippath).write
      puts "[STATE::Lambda] Function compressed #{zippath}"

      client = @aws.lambda_client

      begin
        function = client.get_function({function_name: name})
      rescue
        function = nil
      end

      description = File.exist?("#{path}/dbconf.py") ? get_database_config : name
      function_config = get_lambda_config(path)
      timeout = function_config.any? ? function_config["timeout"] : "3"
      memory = function_config.key?("memory") ? function_config["memory"] : "128"
      environment_variables = function_config.key?("env") ? function_config["env"] : {}

      unless function
        args = {}
        args[:role] = role.arn
        args[:function_name] = name
        args[:handler] = 'lambda_function.lambda_handler'
        args[:description] = description
        args[:timeout] = timeout
        args[:memory_size] = memory
        args[:environment] = { variables: environment_variables }
        args[:runtime] = 'python2.7'
          code = {}
          code[:zip_file] = IO.read zippath
        args[:code] = code

        unless test?
          args[:vpc_config] = get_vpc_config(path)
        end
        args[:description] = get_database_config

        resp = client.create_function(args)
        puts "[STATE::Lambda] deployed (created) #{resp.function_arn}"
      else
        resp = client.update_function_code({function_name: name, zip_file: IO.read(zippath)})
        resp = client.update_function_configuration({
          function_name: name,
          description: description,
          timeout: timeout,
          memory_size: memory,
          environment: { variables: environment_variables},
          role: role.arn})
        puts "[STATE::Lambda] deployed (updated) #{resp.function_arn}"
      end

      clean(path)
      resp.function_arn
    end


    def link_resource(name="")
      path = to_path(name)
      policy = get_policy_config(path)

      policy_doc = policy_template
      policy.keys.map{|resource_name|
        doc = self.send("link_resource_#{resource_name}", name, policy[resource_name])
        policy_doc["Statement"].push doc if doc
        puts "[STATE::Resource] deployed link to lambda #{name} => #{resource_name} => #{policy[resource_name].join(",")}"
      }
      attach_policy name, policy_doc
    end


    def link_resource_s3(sender_lambda, receiver)
      s3 = @aws.s3
      lambda_client = @aws.lambda_client

      bucket_arns = []
      receiver.map{|config|
        base_name = config["name"]
        bucket_name = test? ? "staging-#{base_name}" : base_name
        begin
          s3.create_bucket({bucket: bucket_name})
          puts "[STATE::S3] deployed bucket (created) #{bucket_name}"
        rescue Exception => e
          puts e
          puts "[STATE::S3] deployed bucket (exist) #{bucket_name}"
        end

        if config.key?("is_event_source")
          resp = lambda_client.get_policy({function_name: sender_lambda})
          JSON.load(resp.policy)['Statement'].map do |pol|
            puts "[STATE::S3] clear permission. #{sender_lambda}, #{pol["Sid"]}"
            lambda_client.remove_permission({function_name: sender_lambda, statement_id: pol['Sid']})
          end
          lambda_client.add_permission s3_lambda_permission(sender_lambda, "arn:aws:s3:::#{bucket_name}")
          puts "[STATE::S3] as event source => #{bucket_name}"
        else
          puts "[STATE::S3] just as data store => #{bucket_name}"
        end

        bucket_arns.push "arn:aws:s3:::#{bucket_name}/*"
      }
      s3_policy_doc bucket_arns
    end


    def link_resource_sns(sender_lambda, receiver_lambdas)
      sns = @aws.sns
      lambda_client = @aws.lambda_client

      topic_arns = []
      convention = split(sender_lambda)
      receiver_lambdas.map{|topic_name|
        linker_name = build_name convention["feature"], topic_name
        topic = sns.create_topic({name: linker_name})

        begin
          lambda_function = lambda_client.get_function({function_name: linker_name})
          topic.subscribe({protocol: "lambda", endpoint: lambda_function.configuration.function_arn})
          lambda_client.add_permission(sns_lambda_permission(linker_name, topic.arn))
          puts "[STATE::SNS] deployed #{topic.arn} => #{lambda_function.configuration.function_arn}"
        rescue
          puts "[STATE::SNS] subscription in SNS not found( or it is not deployed yet ) => #{linker_name}"
        end

        topic_arns.push topic.arn
      }

      sns_policy_doc topic_arns
    end

    def link_resource_dynamodb(sender_lambda, receiver)
      dynamo = @aws.dynamo

      table_arns = []
      receiver.map{|name|
        resp = dynamo.describe_table({table_name: name})
        table_arns.push resp.table.table_arn
        resp.table.global_secondary_indexes.each do |index|
          table_arns.push index.index_arn
        end
      }
      puts "[STATE::DynamoDB] deployed #{table_arns.join(",")}"

      dynamo_policy_doc table_arns
    end

    def link_resource_sqs(sender_lambda, receiver)
      sqs = @aws.sqs
      resource = get_resource()
      queue_arns = []
      receiver.map{|queue|
        args = {}
        args[:queue_name] = queue
        attributes = {}
        attributes["DelaySeconds"] = resource["sqs"][queue]["delay"]
        resp = sqs.create_queue(args)
        resp = sqs.get_queue_attributes({queue_url: resp.queue_url, attribute_names:["QueueArn"]})
        queue_arns.push resp.attributes["QueueArn"]
      }
      puts "[STATE::SQS] deployed #{queue_arns.join(",")}"
      sqs_policy_doc queue_arns
    end

    def attach_policy(name="", policy_doc=nil)
      iam = @aws.iam
      sts = @aws.sts

      if test?
        puts "[STATE::IAM] deploying skipped staging role."
        return
      end

      role = iam.role name
      common_policy = {}
      open(".policy.json") {|f| common_policy = JSON.load(f)}
      common_policy.each do |policy|
        role.attach_policy({policy_arn: policy})
        puts "[STATE::POLICY] attach policy. #{policy} => #{role.arn}"
      end

      if policy_doc && policy_doc["Statement"].any?
        begin
          unique_policy = iam.policy "arn:aws:iam::#{sts.get_caller_identity.account}:policy/#{name}"
          unique_policy.versions.map{|pol| pol.delete unless pol.is_default_version}
          unique_policy.create_version({policy_document: policy_doc.to_json, set_as_default: true})
        rescue Exception => e
          puts e
          unique_policy = nil
          is_new = true
        end
        puts unique_policy
        if is_new
          unique_policy = iam.create_policy({policy_name: name, policy_document: policy_doc.to_json})
        end

        role.attach_policy({policy_arn: unique_policy.arn})
        puts "[STATE::POLICY] attach policy. #{unique_policy.arn} => #{role.arn}"
      end

      vpc = get_vpc_config to_path(name)
      if vpc.any?
        role.attach_policy({policy_arn: "arn:aws:iam::aws:policy/service-role/AWSLambdaVPCAccessExecutionRole"})
        puts "[STATE::POLICY] attach policy. (lambda belongs to VPC) AWSLambdaVPCAccessExecutionRole => #{role.arn}"
      end
    end


    def copy_imports_libs(path)
      file = "#{path}/.import.json"
      if File.exist?(file)
        libs = open("#{path}/.import.json"){|f| libs = JSON.load(f)}
        libs.map{|lib|
          FileUtils.cp_r(Dir.glob("./deliver/#{lib}/*"), path)
          # FileUtils.cp_r("./deliver/#{lib}/", path)
          method_name = "custormize_#{lib}"

          self.send(method_name, path) if ConventionallyDeployment.private_method_defined?(method_name)
          puts "[Lambda::function] imported from #{lib}"
        }
      end
    end


    def custormize_sns_glue(path)
      file = "#{path}/sns_glue.py"
      policy = get_policy_config(path)

      if File.exist?(file) && policy.any? && policy.key?("sns")
        topic_names = policy["sns"]
        publish_methods = ""
        deploy_topic_names = {}
        code = File.read(file)
        topic_names.map{|topic_name|
          element = split_path(path)
          linker_name = build_name element["feature"], topic_name
          deploy_topic_names[topic_name] = linker_name
          template = <<-EOF.unindent
            def publish_to_#{topic_name}(message):
                publish("#{linker_name}", message)
          EOF

          publish_methods << template
        }
        code.gsub! /"<<replaced>> publish_to_specified_topic"/, publish_methods
        code.gsub! /"<<replaced>> topic_names_constants"/, "TOPIC_NAMES=#{deploy_topic_names.to_json}"
        File.write file, code
      end
    end


    def custormize_s3_glue(path)
      file = "#{path}/s3_glue.py"
      policy = get_policy_config(path)
      if File.exist?(file) && policy.any? && policy.key?("s3")
        bucket_names = policy["s3"]
        # methods = ""
        deploy_bucket_names = {}
        bucket_names.map{|convention|
          name = convention["name"]
          bucket_name = test? ? "staging-#{name}" : name
          deploy_bucket_names[name] = bucket_name
          # template = <<-EOF.unindent
          #   def get_object_from_#{name.gsub(/\./,"_")}(key):
          #       bucket_name = "#{bucket_name}"
          #       obj = get(bucket_name, key)
          #       return obj
          #
          #
          #   def put_object_to_#{name.gsub(/\./,"_")}(key, data):
          #       bucket_name = "#{bucket_name}"
          #       obj = bucket.put(bucket_name, key, data)
          #       return obj
          # EOF
          # methods << template
        }
        code = File.read(file)
        code.gsub! /"<<replaced>> publish_to_specified_bucket"/, "BUCKET_NAMES = #{deploy_bucket_names.to_json}"
        File.write file, code
      end
    end


    def get_lambda_config(path)
      file = "#{path}/.lambda.json"
      if File.exist?(file)
        get_config(file)
      else
        {}
      end
    end

    def get_vpc_config(path)
      file = "#{path}/.vpc.json"
      if File.exist?(file)
        get_config(file)
      else
        {}
      end
    end

    def get_database_config()
      file = "./.database.json"
      if File.exist?(file)
        hosts = get_config(file)
        host = hosts[env] if hosts.any?
        host.to_json
      else
        ""
      end
    end

    def get_imports_config(path)
      file = "#{path}/.import.json"
      if File.exist?(file)
        get_config(file)
      else
        {}
      end
    end

    def get_policy_config(path)
      file = "#{path}/.policy.json"
      if File.exist?(file)
        get_config(file)
      else
        {}
      end
    end

    def get_config(path)
      json_h = {}
      open(path){|f| json_h = JSON.load(f)}
      json_h
    end

    def get_resource()
      file = "./.resource.json"
      if File.exist?(file)
        get_config(file)
      else
        {}
      end
    end

    def clean(path)
      zippath = "#{path}/app.zip"
      File.delete zippath

      libs = get_imports_config(path)
      libs.map{|lib|
        Dir.entries("./deliver/#{lib}")[2..-1].map{|file|
          FileUtils.rm_rf "#{path}/#{file}"
        }
      }
      puts "[OPERATION::CLEAN] #{zippath}, #{libs}"
    end

    def build_name(feature, action)
      "#{@project}-#{feature}-#{action}"
    end

    def to_path(deploy_name)
      element = split(deploy_name)
      "../#{element["feature"]}/#{element["action"]}"
    end

    def split(deploy_name)
      array = [["project","feature","action"], deploy_name.split("-")].transpose
      Hash[*array.flatten]
    end

    def split_path(path)
      array = [["project","feature","action"], path.split("/")].transpose
      Hash[*array.flatten]
    end

    def test?()
      @test
    end

    def env()
      @test ? "test" : "release"
    end
end

#
# Prompt handling...
#
arg_function = ARGV.grep(/-function=.+/)
function = arg_function[0][10..-1] if arg_function.any?

arg_feature = ARGV.grep(/-feature=.+/)
feature = arg_feature[0][9..-1] if arg_feature.any?

arg_region = ARGV.grep(/-region=.+/)
if arg_region.any?
  region = arg_region[0][8..-1]
else
  region = "ap-northeast-2"
end

runner = ConventionallyDeployment.new(region, ARGV.include?("-test"))

# deploy
if function
  runner.deploy_single_function(function)
elsif feature
  runner.deploy_feature(feature)
else
  runner.deploy_all_functions
end
