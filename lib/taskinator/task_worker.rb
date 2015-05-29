module Taskinator
  class TaskWorker
    attr_reader :uuid

    def initialize(uuid)
      @uuid = uuid
    end

    def perform
      task = Taskinator::Task.fetch(@uuid)
      return if task.paused? || task.cancelled?
      begin
        task.start!
        task.complete! if task.can_complete?
      rescue Exception => e
        Taskinator.logger.error(e)
        task.fail!(e)
        raise e
      end
    end
  end
end
