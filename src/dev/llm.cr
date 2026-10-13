# src/dev/llm.cr
require "http/client"
require "json"
require "./cli"

module Dev::LLM
  extend self

  ENDPOINT        = URI.parse("https://api.deepseek.com/chat/completions")
  KEY_ENV         = "DEEPSEEK_API_KEY"
  MODEL_ENV       = "PROJECT_LLM_MODEL"
  DEFAULT_MODEL   = "deepseek-flash"
  MAX_TOKENS      = 2048
  CONNECT_TIMEOUT = 10.seconds
  READ_TIMEOUT    = 90.seconds
  ERROR_PREVIEW   = 300
  COUNT_WORKERS   = 8
  PROBE           = "a"
  PROBE_TOKENS    = 1

  class Failure < Exception
  end

  record Message, role : String, content : String do
    include JSON::Serializable
  end

  record Mode, type : String do
    include JSON::Serializable
  end

  record Request, model : String, messages : Array(Message), thinking : Mode,
    max_tokens : Int32, stream : Bool, response_format : Mode? = nil do
    include JSON::Serializable
  end

  struct Usage
    include JSON::Serializable

    getter prompt_tokens : Int64 = 0_i64
    getter completion_tokens : Int64 = 0_i64
  end

  struct Reply
    include JSON::Serializable

    getter content : String?
  end

  struct Choice
    include JSON::Serializable

    getter message : Reply
    getter finish_reason : String?
  end

  struct Response
    include JSON::Serializable

    getter choices : Array(Choice) = [] of Choice
    getter usage : Usage?
  end

  record Completion, content : String, usage : Usage?

  def key : String?
    ENV[KEY_ENV]?.presence
  end

  def model : String
    ENV[MODEL_ENV]?.presence || DEFAULT_MODEL
  end

  def available? : Bool
    !key.nil? && STDIN.tty? && STDOUT.tty?
  end

  def require_key : String
    key || CLI.die("set $#{KEY_ENV} to use DeepSeek")
  end

  def label(usage : Usage?) : String
    return model unless usage
    "#{model}, #{compact(usage.prompt_tokens)} in / #{compact(usage.completion_tokens)} out"
  end

  def compact(count : Int) : String
    count < 1000 ? count.to_s : "#{(count / 1000).round(1)}k"
  end

  def complete(system : String, user : String) : Completion
    request = Request.new(model, [Message.new("system", system), Message.new("user", user)],
      Mode.new("disabled"), MAX_TOKENS, false, Mode.new("json_object"))
    response = session { |client| post(client, request) }
    choice   = response.choices.first? || raise Failure.new("no choices in the response")
    raise Failure.new("response cut off (finish_reason: length)") if choice.finish_reason == "length"
    content = choice.message.content
    raise Failure.new("empty content") if content.nil? || content.blank?
    Completion.new(content, response.usage)
  end

  def token_counts(texts : Array(String)) : Array(Int64?)
    overhead = session { |client| prompt_tokens(client, PROBE) } - PROBE_TOKENS
    counts   = Array(Int64?).new(texts.size, nil)
    queue    = Channel(Int32).new(texts.size)
    texts.each_index { |index| queue.send(index) }
    queue.close
    done    = Channel(Nil).new
    workers = Math.min(COUNT_WORKERS, texts.size)
    workers.times do
      spawn do
        session { |client| drain(client, queue, texts, counts, overhead) }
      rescue Failure
      ensure
        done.send(nil)
      end
    end
    workers.times { done.receive }
    counts
  end

  private def drain(client : HTTP::Client, queue : Channel(Int32), texts : Array(String),
                    counts : Array(Int64?), overhead : Int64) : Nil
    while index = queue.receive?
      text = texts[index]
      counts[index] = if text.empty?
                        0_i64
                      else
                        begin
                          prompt_tokens(client, text) - overhead
                        rescue Failure
                          nil
                        end
                      end
    end
  end

  private def prompt_tokens(client : HTTP::Client, text : String) : Int64
    request = Request.new(model, [Message.new("user", text)], Mode.new("disabled"), 1, false)
    usage   = post(client, request).usage || raise Failure.new("no usage in the response")
    usage.prompt_tokens
  end

  private def session(&)
    client = HTTP::Client.new(ENDPOINT)
    client.connect_timeout = CONNECT_TIMEOUT
    client.read_timeout = READ_TIMEOUT
    yield client
  ensure
    client.try &.close
  end

  private def post(client : HTTP::Client, request : Request) : Response
    token    = key || raise Failure.new("#{KEY_ENV} is not set")
    headers  = HTTP::Headers{"Authorization" => "Bearer #{token}", "Content-Type" => "application/json"}
    response = client.post(ENDPOINT.path, headers: headers, body: request.to_json)
    unless response.success?
      raise Failure.new("HTTP #{response.status_code}: #{response.body[0, ERROR_PREVIEW].strip}")
    end
    Response.from_json(response.body)
  rescue ex : IO::Error | OpenSSL::Error | JSON::ParseException
    raise Failure.new(ex.message || ex.class.name)
  end
end
