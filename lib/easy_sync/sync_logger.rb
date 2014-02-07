require 'logger'


module EasySync

  class SyncLogger
    attr_reader :log

    def initialize(path)
      @log = Logger.new(path)
    end

    def info(message)
      puts message
      log.info message
    end

  end

end
