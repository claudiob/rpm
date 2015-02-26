# encoding: utf-8
# This file is distributed under New Relic's license terms.
# See https://github.com/newrelic/rpm/blob/master/LICENSE for complete details.

require File.join(File.dirname(__FILE__), 'database.rb')
require File.join(File.dirname(__FILE__), 'sequel_helpers.rb')

if Sequel.const_defined?( :MAJOR ) &&
      ( Sequel::MAJOR > 3 ||
        Sequel::MAJOR == 3 && Sequel::MINOR >= 37 )

require 'newrelic_rpm'

class SequelExtensionTest < Minitest::Test
  include SequelHelpers

  def setup
    super

    DB.extension :newrelic_instrumentation

    @posts = DB[:posts]

    NewRelic::Agent.disable_all_tracing do
      post_id = @posts.insert( :title => 'All The Things', :content => 'A nice short story.' )
      @post = @posts[:id => post_id]
    end
  end

  def teardown
    super

    NewRelic::Agent.shutdown
  end

  def expected_metrics_for_operation(operation)
    [
      ["Datastore/operation/#{product_name}/#{operation}", "dummy"],
      "Datastore/operation/#{product_name}/#{operation}",
      "Datastore/#{product_name}/allWeb",
      "Datastore/allWeb",
      "Datastore/#{product_name}/all",
      "Datastore/all"
    ]
  end

  def test_all
    in_web_transaction { @posts.all }

    assert_datastore_metrics_recorded_exclusive(expected_metrics_for_operation(:select))
  end

  def test_find
    in_web_transaction do
      @posts[:id => 11]
    end

    assert_datastore_metrics_recorded_exclusive(expected_metrics_for_operation(:select))
  end

  def test_model_create_method_generates_metrics
    in_web_transaction do
      @posts.insert( :title => 'The Thing', :content => 'A wicked short story.' )
    end

    assert_datastore_metrics_recorded_exclusive(expected_metrics_for_operation(:insert))
  end

  def test_update
    in_web_transaction do
      @posts.where(:id => @post[:id]).update( :title => 'A Lot of the Things' )
    end

    assert_datastore_metrics_recorded_exclusive(expected_metrics_for_operation(:update))
  end

  def test_delete
    in_web_transaction do
      @posts.where(:id => @post[:id]).delete
    end

    assert_datastore_metrics_recorded_exclusive(expected_metrics_for_operation(:delete))
  end

  def test_slow_queries_get_an_explain_plan
    with_config( :'transaction_tracer.explain_threshold' => -0.01,
                 :'transaction_tracer.record_sql' => 'raw' ) do
      segment = last_segment_for do
        @posts[:id => 11]
      end
      assert_match %r{select \* from `posts` where \(?`id` = 11\)?( limit 1)?}i, segment.params[:sql]
      assert_segment_has_explain_plan( segment )
    end
  end

  def test_sql_is_recorded_in_tt_for_non_select
    with_config(:'transaction_tracer.record_sql' => 'raw') do
      segment = last_segment_for do
        @posts.insert(:title => 'title', :content => 'content')
      end
      assert_match %r{insert into `posts` \([^\)]*\) values \([^\)]*\)}i, segment.params[:sql]
    end
  end

  def test_queries_can_get_explain_plan_with_obfuscated_sql
    config = {
      :'transaction_tracer.explain_threshold' => -0.01,
      :'transaction_tracer.record_sql' => 'obfuscated'
    }
    with_config(config) do
      segment = last_segment_for(:record_sql => :obfuscated) do
        @posts[:id => 11]
      end
      assert_match %r{select \* from `posts` where \(?`id` = \?\)?}i, segment.params[:sql]
      assert_segment_has_explain_plan( segment )
    end
  end

  def test_notices_sql_with_proper_metric_name
    config = {
      :'transaction_tracer.explain_threshold' => -0.01,
      :'transaction_tracer.record_sql' => 'obfuscated'
    }
    with_config(config) do
      in_web_transaction { Post.all }
      expected_metric_name = "Datastore/operation/#{product_name}/select"
      recorded_metric_names = NewRelic::Agent.agent.sql_sampler.sql_traces.values.map(&:database_metric_name)
      assert recorded_metric_names.include? expected_metric_name
    end
  end
end

else
  puts "Skipping tests in #{__FILE__} because unsupported Sequel version"
end
