require 'spec_helper'

describe Rsync do
#Time.now.strftime "%Y-%m-%d-%H%M%S"
  
  it "should find the latest snapshot" do
    Rsync.new("","").last_snapshot.must_equal ""
  end

  def temp_files
    
  end
  
end
