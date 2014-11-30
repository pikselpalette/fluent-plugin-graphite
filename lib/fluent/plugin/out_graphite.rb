require 'fluent/mixin/rewrite_tag_name'

class Fluent::GraphiteOutput < Fluent::BufferedOutput
  class ConnectionFailure < StandardError; end
  Fluent::Plugin.register_output('graphite', self)

  include Fluent::HandleTagNameMixin
  include Fluent::Mixin::RewriteTagName

  config_param :host, :string
  config_param :port, :integer, default: 2003
  config_param :tag_for, :string, default: 'prefix'
  config_param :name_keys, :string, default: nil
  config_param :name_key_pattern, :string, default: nil

  # Define `log` method for v0.10.42 or earlier
  unless method_defined?(:log)
    define_method(:log) { $log }
  end

  def initialize
    super
  end

  def start
    super
    @client = Graphite.new(@host, @port)
  end

  def shutdown
    super
  end

  def configure(conf)
    super

    if !['prefix', 'suffix', 'ignore'].include?(@tag_for)
      raise Fluent::ConfigError, 'out_graphite: can specify to tag_for only prefix, suffix or ignore'
    end

    if !@name_keys && !@name_key_pattern
      raise Fluent::ConfigError, 'out_graphite: missing both of name_keys and name_key_pattern'
    end
    if @name_keys && @name_key_pattern
      raise Fluent::ConfigError, 'out_graphite: cannot specify both of name_keys and name_key_pattern'
    end

    if @name_keys
      @name_keys = @name_keys.split(',')
    end
    if @name_key_pattern
      @name_key_pattern = Regexp.new(@name_key_pattern)
    end
  end

  def format(tag, time, record)
    [tag, time, record].to_msgpack
  end

  def write(chunk)
    chunk.msgpack_each { |tag, time, record|
      emit_tag = tag.dup
      filter_record(emit_tag, time, record)
      next unless metrics = format_metrics(emit_tag, record)

      # implemented to immediate call post method in this loop, because graphite-api.gem has the buffers.
      post(metrics, time)
    }
  end

  def remap(data)
    if data.is_a? String
      if data =~ /^\d+\.\d+$/
        data = data.to_f
      elsif data =~ /^\d+$/
        data = data.to_i
      else
        nil
      end
    end
    data
  end

  def format_metrics(tag, record)
    filtered_record = if @name_keys
                        record.select { |k,v| @name_keys.include?(k) }
                      else # defined @name_key_pattern
                        record.select { |k,v| @name_key_pattern.match(k) }
                      end

    return nil if filtered_record.empty?

    metrics = {}
    tag = tag.sub(/\.$/, '') # may include a dot at the end of the emit_tag fluent-mixin-rewrite-tag-name returns. remove it.
    filtered_record.each do |k, v|
      key = case @tag_for
            when 'ignore' then k
            when 'prefix' then tag + '.' + k
            when 'suffix' then k + '.' + tag
            end

      key = key.gsub(/(\s|\/)+/, '_') # cope with in the case of containing symbols or spaces in the key of the record like in_dstat.
      next unless v = remap(v)
      metrics[key] = v
    end
    metrics
  end

  def post(metrics, time)
    retries = 0
    begin
      @client.post(metrics, time)
    rescue Exception => e
      if retries < 2
        retries += 1
        log.warn "Could not push metrics to Graphite, resetting connection and trying again. #{e.message}"
        sleep 2**retries
        retry
      end
      raise ConnectionFailure, "Could not push metrics to Graphite after #{retries} retries. #{e.message}"
    end
  end

  class Graphite
    attr_reader :host, :port
    def initialize(host, port)
      @host = host
      @port = port
    end

    def post(message, time)
      TCPSocket.open(@host, @port) { |socket|
        message.each { |key, value|
          msg = "#{key} #{value} #{time}\n"
          socket.write(msg)
        }
      }
    end
  end
end
