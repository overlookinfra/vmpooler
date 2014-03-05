module Vmpooler
  class API
    def initialize
      # Load the configuration file
      config_file = File.expand_path('vmpooler.yaml')
      $config = YAML.load_file(config_file)

      pools = $config[:pools]
      redis = $config[:redis]

      # Set some defaults
      $config[:redis] ||= Hash.new
      $config[:redis]['server'] ||= 'localhost'

      # Connect to Redis
      $redis = Redis.new(:host => $config[:redis]['server'])
    end

    def execute!
      my_app = Sinatra.new {

        set :environment, 'production'

        get '/' do
          erb :dashboard, locals: {
            site_name: $config[:config]['site_name'] || '<b>vmpooler</b>',
          }
        end

        get '/dashboard/stats/vmpooler/numbers/?' do
          result = Hash.new
          result['pending'] = 0
          result['cloning'] = 0
          result['booting'] = 0
          result['ready'] = 0
          result['running'] = 0
          result['completed'] = 0

          $config[:pools].each do |pool|
            result['pending'] += $redis.scard( 'vmpooler__pending__' + pool['name'] )
            result['ready'] += $redis.scard( 'vmpooler__ready__' + pool['name'] )
            result['running'] += $redis.scard( 'vmpooler__running__' + pool['name'] )
            result['completed'] += $redis.scard( 'vmpooler__completed__' + pool['name'] )
          end

          result['cloning'] = $redis.get( 'vmpooler__tasks__clone' )
          result['booting'] = result['pending'].to_i - result['cloning'].to_i
          result['booting'] = 0 if result['booting'] < 0
          result['total'] = result['pending'].to_i + result['ready'].to_i + result['running'].to_i + result['completed'].to_i

          content_type :json
          JSON.pretty_generate(result)
        end

        get '/dashboard/stats/vmpooler/pool/?' do
          result = Hash.new

          $config[:pools].each do |pool|
            result[pool['name']] ||= Hash.new
            result[pool['name']]['size'] = pool['size']
            result[pool['name']]['ready'] = $redis.scard( 'vmpooler__ready__' + pool['name'] )
          end

          if ( params[:history] )
            if ( $config[:config]['graphite'] )
              history ||= Hash.new

              begin
                buffer = open( 'http://'+$config[:config]['graphite']+'/render?target=vmpooler.ready.*&from=-1hour&format=json' ).read
                history = JSON.parse( buffer )

                history.each do |pool|
                  if pool['target'] =~ /.*\.(.*)$/
                    pool['name'] = $1

                    if ( result[pool['name']] )
                      pool['last'] = result[pool['name']]['size']
                      result[pool['name']]['history'] ||= Array.new

                      pool['datapoints'].each do |metric|
                        8.times do |n|
                          if ( metric[0] )
                            pool['last'] = metric[0].to_i
                            result[pool['name']]['history'].push( metric[0].to_i )
                          else
                            result[pool['name']]['history'].push( pool['last'] )
                          end
                        end
                      end
                    end
                  end
                end
              rescue
              end
            else
              $config[:pools].each do |pool|
                result[pool['name']] ||= Hash.new
                result[pool['name']]['history'] = [ $redis.scard( 'vmpooler__ready__' + pool['name'] ) ]
              end
            end
          end

          content_type :json
          JSON.pretty_generate(result)
        end

        get '/dashboard/stats/vmpooler/running/?' do
          result = Hash.new

          $config[:pools].each do |pool|
            running = $redis.scard( 'vmpooler__running__' + pool['name'] )
            pool['major'] = $1 if pool['name'] =~ /^(\w+)\-/

            result[pool['major']] ||= Hash.new

            result[pool['major']]['running'] = result[pool['major']]['running'].to_i + running.to_i
          end

          if ( params[:history] )
            if ( $config[:config]['graphite'] )
              begin
                buffer = open( 'http://'+$config[:config]['graphite']+'/render?target=vmpooler.running.*&from=-1hour&format=json' ).read
                JSON.parse( buffer ).each do |pool|
                  if pool['target'] =~ /.*\.(.*)$/
                    pool['name'] = $1

                    pool['major'] = $1 if pool['name'] =~ /^(\w+)\-/

                    result[pool['major']]['history'] ||= Array.new

                    for i in 0..pool['datapoints'].length
                      if (
                        pool['datapoints'][i] and
                        pool['datapoints'][i][0]
                      )
                        pool['last'] = pool['datapoints'][i][0]

                        result[pool['major']]['history'][i] ||= 0
                        result[pool['major']]['history'][i] = result[pool['major']]['history'][i].to_i + pool['datapoints'][i][0].to_i
                      else
                        result[pool['major']]['history'][i] = result[pool['major']]['history'][i].to_i + pool['last'].to_i
                      end
                    end

                  end
                end
              rescue
              end
            end
          end

          content_type :json
          JSON.pretty_generate(result)
        end

        get '/vm/?' do
          content_type :json

          result = []

          $config[:pools].each do |pool|
            result.push(pool['name'])
          end

          JSON.pretty_generate(result)
        end

        get '/vm/:template/?' do
          content_type :json

          result = {}
          result[params[:template]] = {}
          result[params[:template]]['hosts'] = $redis.smembers('vmpooler__ready__'+params[:template])

          JSON.pretty_generate(result)
        end

        post '/vm/:template/?' do
          content_type :json

          result = {}
          result[params[:template]] = {}

          if ( $redis.scard('vmpooler__ready__'+params[:template]) > 0 )
            vm = $redis.spop('vmpooler__ready__'+params[:template])

            unless (vm.nil?)
              $redis.sadd('vmpooler__running__'+params[:template], vm)
              $redis.hset('vmpooler__active__'+params[:template], vm, Time.now)

              result[params[:template]]['ok'] = true
              result[params[:template]]['hostname'] = vm
            else
              result[params[:template]]['ok'] = false
            end
          else
            result[params[:template]]['ok'] = false
          end

          JSON.pretty_generate(result)
        end

        delete '/vm/:hostname/?' do
          content_type :json

          result = {}

          result['ok'] = false

          $config[:pools].each do |pool|
            if $redis.sismember('vmpooler__running__'+pool['name'], params[:hostname])
              $redis.srem('vmpooler__running__'+pool['name'], params[:hostname])
              $redis.sadd('vmpooler__completed__'+pool['name'], params[:hostname])
              result['ok'] = true
            end
          end

          JSON.pretty_generate(result)
        end
      }

      my_app.run!
    end
  end
end

