require 'thread'
require 'thwait'

module Taskinator
  class Process
    include ::Comparable

    include Workflow
    include Persistence
    include Instrumentation

    class << self
      def define_sequential_process_for(definition, options={})
        Process::Sequential.new(definition, options)
      end

      def define_concurrent_process_for(definition, complete_on=CompleteOn::Default, options={})
        Process::Concurrent.new(definition, complete_on, options)
      end

      def base_key
        'process'
      end
    end

    attr_reader :uuid
    attr_reader :definition
    attr_reader :options
    attr_reader :queue
    attr_reader :created_at
    attr_reader :updated_at

    # in the case of sub process tasks, the containing task
    attr_accessor :parent

    def initialize(definition, options={})
      raise ArgumentError, 'definition' if definition.nil?
      raise ArgumentError, "#{definition.name} does not extend the #{Definition.name} module" unless definition.kind_of?(Definition)

      @uuid = options.delete(:uuid) || SecureRandom.uuid
      @definition = definition
      @options = options
      @queue = options.delete(:queue)
      @created_at = Time.now.utc
      @updated_at = created_at
    end

    def tasks
      @tasks ||= Tasks.new
    end

    def no_tasks_defined?
      tasks.empty?
    end

    def accept(visitor)
      visitor.visit_attribute(:uuid)
      visitor.visit_task_reference(:parent)
      visitor.visit_type(:definition)
      visitor.visit_tasks(tasks)
      visitor.visit_args(:options)
      visitor.visit_attribute(:queue)
      visitor.visit_attribute_time(:created_at)
      visitor.visit_attribute_time(:updated_at)
    end

    def <=>(other)
      uuid <=> other.uuid
    end

    def to_s
      "#<#{self.class.name}:#{uuid}>"
    end

    def enqueue!
      return if paused? || cancelled?

      transition(:enqueued) do
        instrument('taskinator.process.enqueued', enqueued_payload) do
          enqueue
        end
      end
    end

    def start!
      return if paused? || cancelled?

      transition(:processing) do
        instrument('taskinator.process.processing', processing_payload) do
          start
        end
      end
    end

    def pause!
      return unless enqueued? || processing?

      transition(:paused) do
        instrument('taskinator.process.paused', paused_payload) do
          pause if respond_to?(:pause)
        end
      end
    end

    def resume!
      return unless paused?

      transition(:processing) do
        instrument('taskinator.process.resumed', resumed_payload) do
          resume if respond_to?(:resume)
        end
      end
    end

    def complete!
      transition(:completed) do
        instrument('taskinator.process.completed', completed_payload) do
          complete if respond_to?(:complete)
          # notify the parent task (if there is one) that this process has completed
          # note: parent may be a proxy, so explicity check for nil?
          parent.complete! unless parent.nil?
        end
      end
    end

    def tasks_completed?
      # TODO: optimize this
      tasks.all?(&:completed?)
    end

    def cancel!
      transition(:cancelled) do
        instrument('taskinator.process.cancelled', cancelled_payload) do
          cancel if respond_to?(:cancel)
        end
      end
    end

    def fail!(error)
      transition(:failed) do
        instrument('taskinator.process.failed', failed_payload(error)) do
          fail(error) if respond_to?(:fail)
          # notify the parent task (if there is one) that this process has failed
          # note: parent may be a proxy, so explicity check for nil?
          parent.fail!(error) unless parent.nil?
        end
      end
    end

    def task_failed(task, error)
      # for now, fail this process
      fail!(error)
    end

    #--------------------------------------------------
    # subclasses must implement the following methods
    #--------------------------------------------------

    def enqueue
      raise NotImplementedError
    end

    def start
      raise NotImplementedError
    end

    def task_completed(task)
      raise NotImplementedError
    end

    #--------------------------------------------------

    class Sequential < Process
      def enqueue
        if tasks.empty?
          complete! # weren't any tasks to start with
        else
          tasks.first.enqueue!
        end
      end

      def start
        task = tasks.first
        if task
          task.start!
        else
          complete! # weren't any tasks to start with
        end
      end

      def task_completed(task)
        next_task = task.next
        if next_task
          next_task.enqueue!
        else
          complete! # aren't any more tasks
        end
      end

      def inspect
        %(#<#{self.class.name}:0x#{self.__id__.to_s(16)} uuid="#{uuid}", state=:#{current_state}, tasks=[#{tasks.inspect}]>)
      end
    end

    #--------------------------------------------------

    class Concurrent < Process
      attr_reader :complete_on
      attr_reader :concurrency_method

      def initialize(definition, complete_on=CompleteOn::Default, options={})
        super(definition, options)
        @complete_on = complete_on
        @concurrency_method = options.delete(:concurrency_method) || :thread
      end

      def enqueue
        if tasks.empty?
          complete! # weren't any tasks to start with
        else
          tasks.each(&:enqueue!)
        end
      end

      def start
        if tasks.empty?
          complete! # weren't any tasks to start with
        else
          if concurrency_method == :fork
            tasks.each do |task|
              fork do
                task.start!
              end
            end
            Process.waitall
          else
            threads = tasks.map do |task|
              Thread.new do
                task.start!
              end
            end
            ThreadsWait.all_waits(*threads)
          end
        end
      end

      def task_completed(task)
        # when complete on first, then don't bother with subsequent tasks completing
        return if completed? || failed?
        complete!
      end

      def tasks_completed?
        if (complete_on == CompleteOn::First)
          tasks.any?(&:completed?)
        else
          super # all
        end
      end

      def accept(visitor)
        super
        visitor.visit_attribute_enum(:complete_on, CompleteOn)
      end

      def inspect
        %(#<#{self.class.name}:0x#{self.__id__.to_s(16)} uuid="#{uuid}", state=:#{current_state}, complete_on=:#{complete_on}, tasks=[#{tasks.inspect}]>)
      end
    end
  end
end
