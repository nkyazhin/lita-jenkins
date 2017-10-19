require 'jenkins_api_client'
require 'json'
require 'http'
require 'awesome_print'

module Lita
  module Handlers
    class Jenkins < Handler

      namespace "jenkins"

      config :server, required: true
      config :org_domain, required: true

      route /j(?:enkins)? a(?:uth)? (check|set|del)_token( (.+))?/i, :auth, command: true, help: {
        'j(enkins) a(uth) {check|set|del}_token' => 'Check, set or delete your token for playing with Jenkins'
      }

      route /j(?:enkins)? list( (.+))?/i, :list, command: true, help: {
        'jenkins list' => 'Shows all accessable Jenkins jobs with last status'
      }

      route /j(?:enkins)? show( (.+))?/i, :show, command: true, help: {
        'jenkins show <job_name>' => 'Shows info for <job_name> job'
      }

      route /j(?:enkins)? b(?:uild)? ([\w\-]+)( (.+))?/i, :build, command: true, help: {
        'jenkins b(uild) <job_name> param:value,param2:value2' => 'Builds the job specified by name'
      }

      route /j(?:enkins)?(\W+)?d(?:eploy)?(\W+)?([\w\-]+)(\W+)?([\w\-]+)?(\W+)?to(\W+)?([\w\-]+)/i, :deploy, command: true, help: {
        'jenkins d(eploy) <project> <branch> to <stage>' => 'Start dynamic deploy with params. Не выбранный бренч, зальет версию продакшна.'
      }

      def deploy(response)
        params     = response.matches.last.reject(&:blank?) #["avia", "OTT-123", "sandbox-15"]
        project    = params[0]
        branch     = ''
        stage      = ''
        job_name   = 'dynamic_deploy'
        job_params = {}
        opts       = { 'build_start_timeout': 30 }


        if params.size == 3
          branch = params[1]
          stage  = params[2]
        elsif params.size == 2
          stage  = params[1]
        else
          response.reply 'Something wrong with params :fire:'
          return
        end

        job_params['DEPLOY'] = {
          "CHECKMASTER" => true,
          "PROJECTS" => {
            project.upcase => {
              "ENABLE" => true,
              "BRANCH" => branch
            }
          },
          "STAGE" => stage
        }

        client = make_client(response.user.mention_name)

        if client
          begin
            client.job.build(job_name, job_params, opts)
            # username = response.user.mention_name
            # user_full = "#{username}@#{config.org_domain}"
            # token    = redis.get(username)
            # auth     = "#{username}@#{config.org_domain}:#{token}"
            # reply_text = ''

            # path = "https://#{config.server}/job/dynamic_deploy/buildWithParameters?DEPLOY=#{job_params.to_json}"

            # http_resp = HTTP.basic_auth(user: user_full, pass: token).post(path, json: job_params)

            # if http_resp.code == 201
            #   last       = client.job.get_builds(job_name).first
            #   reply_text = "Deploy started :rocket: for #{project} - <#{last['url']}console>"

            #   response.reply reply_text
            # elsif http_resp.code == 400
            #   reply_text = "Jenkins is busy, please try later"
            # else
            #   log.info http_resp.code
            #   ap http_resp
            #   reply_text = 'error'
            # end

            last = client.job.get_builds(job_name).first
            response.reply "Deploy started :rocket: for #{project} - <#{last['url']}console>"
            # response.reply reply_text
          rescue Exception => e
            response.reply "Deploy failed, check params :shia: #{e}"
          end
        else
          "Troubles with request, maybe token is'not set? Try run 'lita jenkins auth check_token'"
        end
      end

      def build(response)
        job_name   = response.matches.last.first
        job_params = {}
        opts       = { 'build_start_timeout': 30 }

        unless response.matches.last.last.nil?
          raw_params = response.matches.last.last

          raw_params.split(',').each do |pair|
            key, value = pair.split(':')
            job_params[key] = value
          end
        end

        client = make_client(response.user.mention_name)

        if client
          begin
            client.job.build(job_name, job_params, opts)
            last = client.job.get_builds(job_name).first
            response.reply "Build started for #{job_name} - <#{last['url']}console>"
          rescue
            response.reply "Build failed, maybe job parametrized?"
          end
        else
          "Troubles with request, maybe token is'not set? Try run 'lita jenkins auth check_token'"
        end
      end

      def auth(response)
        username = response.user.mention_name
        mode     = response.matches.last.first

        reply = case mode
        when 'check'
          user_token = redis.get(username)
          if user_token.nil?
            'Token not found, you need set token via "lita jenkins auth set_token <token>" command'
          else
            'Token already set, you can play with Jenkins'
          end
        when 'set'
          user_token = response.matches.last.last.strip

          if redis.set(username, user_token)
            'Token saved, enjoy!'
          else
            'We have some troubles, try later'
          end
        when 'del'
          user_token = redis.get(username)

          if redis.del(username)
            'Token deleted, so far so good'
          else
            'We have some troubles, try later'
          end
        else
          'Wrong command for "jenkins auth"'
        end

        response.reply reply
      end

      def show(response)
        client = make_client(response.user.mention_name)
        filter = response.matches.first.last

        if client
          job = client.job.list_details(filter)
          response.reply "General: <#{job['url']}|#{job['name']}> - #{job['color']}
Desc: #{job['description']}
Health: #{job['healthReport'][0]['score']} - #{job['healthReport'][0]['description']}
Last build: <#{job['lastBuild']['url']}>"
        else
          response.reply "Troubles with request, maybe token is'not set? Try run 'lita jenkins auth check_token'"
        end
      end

      def list(response)
        client = make_client(response.user.mention_name)
        if client
          answer = ''
          jobs = client.job.list_all_with_details
          jobs.each_with_index do |job, n|
            slackmoji = color_to_slackmoji(job['color'])
            answer << "#{n + 1}. <#{job['url']}|#{job['name']}> - #{job['color']} #{slackmoji}\n"
          end
          response.reply answer
        else
          response.reply "Troubles with request, maybe token is'not set? Try run 'lita jenkins auth check_token'"
        end
      end

      private

      def make_client(username)
        user_token = redis.get(username)

        if user_token.nil?
          false
        else
          JenkinsApi::Client.new(
            server_ip: config.server,
            server_port: '443',
            username: "#{username}@#{config.org_domain}",
            password: user_token,
            ssl: true,
            log_level: 0
          )
        end
      end

      def color_to_slackmoji(color)
        case color
        when 'notbuilt'
          ':new:'
        when 'blue'
          ':woohoo:'
        when 'disabled'
          ':no_bicycles:'
        when 'red'
          ':wide_eye_pepe:'
        when 'yellow'
          ':pikachu:'
        when 'aborted'
          ':ultrarage:'
        end
      end
    end

    Lita.register_handler(Jenkins)
  end
end
