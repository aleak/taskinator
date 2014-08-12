require 'spec_helper'

shared_examples_for "a queue adapter" do |adapter_name, adapter_type|

  subject { adapter_type.new({}) }

  it "should instantiate adapter" do
    Taskinator.queue_adapter = adapter_name
    expect(Taskinator.queue).to be_a(adapter_type)
  end

  it { expect(subject).to respond_to(:enqueue_process) }

  it "should enqueue a process" do
    expect {
      subject.enqueue_process(double('process', :uuid => 'xx-xx-xx-xx'))
    }.to_not raise_error
  end

  it { expect(subject).to respond_to(:enqueue_task) }

  it "should enqueue a task" do
    expect {
      subject.enqueue_task(double('task', :uuid => 'xx-xx-xx-xx'))
    }.to_not raise_error
  end

end