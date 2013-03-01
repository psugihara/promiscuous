require 'spec_helper'

if ORM.has(:mongoid)
  describe Promiscuous do
    before { use_fake_backend }
    before { load_models }
    before { run_subscriber_worker! }

    context 'when using multi reads' do
      it 'publishes proper dependencies' do
        pub = nil
        Promiscuous.transaction do
          pub = PublisherModel.create
          PublisherModel.first
          PublisherModel.first
          pub.update_attributes(:field_1 => 123)
          PublisherModel.first
          PublisherModel.first
          pub.update_attributes(:field_1 => 456)
        end

        dep = Promiscuous::AMQP::Fake.get_next_payload['dependencies']
        dep['link'].should  == nil
        dep['read'].should  == nil
        dep['write'].should == ["publisher_models:id:#{pub.id}:1"]

        dep = Promiscuous::AMQP::Fake.get_next_payload['dependencies']
        dep['link'].should  == "publisher_models:id:#{pub.id}:1"
        dep['read'].should  == ["publisher_models:id:#{pub.id}:1",
                                "publisher_models:id:#{pub.id}:1"]
        dep['write'].should == ["publisher_models:id:#{pub.id}:4"]

        dep = Promiscuous::AMQP::Fake.get_next_payload['dependencies']
        dep['link'].should  == "publisher_models:id:#{pub.id}:4"
        dep['read'].should  == ["publisher_models:id:#{pub.id}:4",
                                "publisher_models:id:#{pub.id}:4"]
        dep['write'].should == ["publisher_models:id:#{pub.id}:7"]
      end
    end

    context 'when using only reads' do
      it 'publishes proper dependencies' do
        pub = without_promiscuous { PublisherModel.create }
        Promiscuous.transaction(:active => true) do
          PublisherModel.first
        end

        payload = Promiscuous::AMQP::Fake.get_next_payload
        payload['__amqp__'].should == "__promiscuous__/dummy"
        payload['operation'].should == "dummy"
        dep = payload['dependencies']
        dep['link'].should  == nil
        dep['read'].should  == ["publisher_models:id:#{pub.id}:0"]
        dep['write'].should == nil
      end
    end

    context 'when using multi reads/writes on tracked attributes' do
      it 'publishes proper dependencies' do
        PublisherModel.track_dependencies_of :field_1
        PublisherModel.track_dependencies_of :field_2

        pub = nil
        Promiscuous.transaction do
          pub = PublisherModel.create(:field_1 => 123, :field_2 => 456)
          PublisherModel.where(:field_1 => 123).count
          PublisherModel.where(:field_1 => 'blah').count
          PublisherModel.where(:field_1 => 123, :field_2 => 456).count
          PublisherModel.where(:field_1 => 'blah', :field_2 => 456).count
          PublisherModel.where(:field_2 => 456).count
          PublisherModel.where(:field_2 => 'blah').count
          PublisherModel.where(:field_2 => 456).first
          pub.update_attributes(:field_1 => 'blah')
          PublisherModel.where(:field_1 => 123).first
          pub.update_attributes(:field_2 => 'blah')
        end

        dep = Promiscuous::AMQP::Fake.get_next_payload['dependencies']
        dep['link'].should  == nil
        dep['read'].should  == nil
        dep['write'].should == ["publisher_models:id:#{pub.id}:1",
                                "publisher_models:field_1:123:1",
                                "publisher_models:field_2:456:1"]

        dep = Promiscuous::AMQP::Fake.get_next_payload['dependencies']
        dep['link'].should  == "publisher_models:id:#{pub.id}:1"
        dep['read'].should  == ["publisher_models:field_1:123:1",
                                "publisher_models:field_1:blah:0",
                                "publisher_models:field_1:123:1",
                                "publisher_models:field_1:blah:0",
                                "publisher_models:field_2:456:1",
                                "publisher_models:field_2:blah:0",
                                "publisher_models:id:#{pub.id}:1"]
        dep['write'].should == ["publisher_models:id:#{pub.id}:3",
                                "publisher_models:field_1:123:4",
                                # FIXME "publisher_models:field_1:blah:3",
                                "publisher_models:field_2:456:3"]

        dep = Promiscuous::AMQP::Fake.get_next_payload['dependencies']
        dep['link'].should  == "publisher_models:id:#{pub.id}:3"
        dep['read'].should  == nil
        dep['write'].should == ["publisher_models:id:#{pub.id}:4",
                                "publisher_models:field_1:blah:3",
                                "publisher_models:field_2:456:4"]
                                # FIXME "publisher_models:field_2:blah:1",
      end
    end

    context 'when using each' do
      it 'publishes proper dependencies' do
        PublisherModel.track_dependencies_of :field_1

        pub1 = pub2 = nil
        Promiscuous.transaction do
          pub1 = PublisherModel.create(:field_1 => 123)
          pub2 = PublisherModel.create(:field_1 => 123)
          PublisherModel.where(:field_1 => 123).each.to_a
          pub1.update_attributes(:field_2 => 456)
        end

        dep = Promiscuous::AMQP::Fake.get_next_payload['dependencies']
        dep['link'].should  == nil
        dep['read'].should  == nil
        dep['write'].should == ["publisher_models:id:#{pub1.id}:1",
                                "publisher_models:field_1:123:1"]

        dep = Promiscuous::AMQP::Fake.get_next_payload['dependencies']
        dep['link'].should  == "publisher_models:id:#{pub1.id}:1"
        dep['read'].should  == nil
        dep['write'].should == ["publisher_models:id:#{pub2.id}:1",
                                "publisher_models:field_1:123:2"]

        dep = Promiscuous::AMQP::Fake.get_next_payload['dependencies']
        dep['link'].should  == "publisher_models:id:#{pub2.id}:1"
        dep['read'].should  == ["publisher_models:field_1:123:2"]
        dep['write'].should == ["publisher_models:id:#{pub1.id}:2",
                                "publisher_models:field_1:123:4"]
      end
    end

    context 'when using a uniqueness validator' do
      it 'skips the query' do
        PublisherModel.validates_uniqueness_of :field_1

        pub = nil
        Promiscuous.transaction do
          pub = PublisherModel.create(:field => 123)
        end

        dep = Promiscuous::AMQP::Fake.get_next_payload['dependencies']
        dep['link'].should  == nil
        dep['read'].should  == nil
        dep['write'].should == ["publisher_models:id:#{pub.id}:1"]
      end
    end

    context 'when using limit(1).each' do
      it 'skips the query' do
        pub1 = pub2 = nil
        Promiscuous.transaction do
          pub1 = PublisherModel.create(:field_1 => 123)
          PublisherModel.all.limit(1).each do |pub|
            pub.id.should      == pub1.id
            pub.field_1.should == pub1.field_1
          end
          pub2 = PublisherModel.create(:field_1 => 123)
        end

        dep = Promiscuous::AMQP::Fake.get_next_payload['dependencies']
        dep['link'].should  == nil
        dep['read'].should  == nil
        dep['write'].should == ["publisher_models:id:#{pub1.id}:1"]

        dep = Promiscuous::AMQP::Fake.get_next_payload['dependencies']
        dep['link'].should  == "publisher_models:id:#{pub1.id}:1"
        dep['read'].should  == ["publisher_models:id:#{pub1.id}:1"]
        dep['write'].should == ["publisher_models:id:#{pub2.id}:1"]
      end
    end

    context 'when updating a field that is not published' do
      it "doesn't track the write" do
        PublisherModel.field :not_published

        pub = nil
        Promiscuous.transaction do
          pub = PublisherModel.create
          pub.update_attributes(:not_published => 'hello')
          pub.update_attributes(:field_1 => 'ohai')
        end

        dep = Promiscuous::AMQP::Fake.get_next_payload['dependencies']
        dep['link'].should  == nil
        dep['read'].should  == nil
        dep['write'].should == ["publisher_models:id:#{pub.id}:1"]

        dep = Promiscuous::AMQP::Fake.get_next_payload['dependencies']
        dep['link'].should  == "publisher_models:id:#{pub.id}:1"
        dep['read'].should  == nil
        dep['write'].should == ["publisher_models:id:#{pub.id}:2"]

        Promiscuous::AMQP::Fake.get_next_message.should == nil
      end
    end

    context 'when using map reduce' do
      it 'track the read' do
        PublisherModel.track_dependencies_of :field_1
        without_promiscuous do
          PublisherModel.create(:field_1 => 123)
          PublisherModel.create(:field_1 => 123)
        end
        Promiscuous.transaction :active => true do
          PublisherModel.where(:field_1 => 123).sum(:field_2)
        end

        dep = Promiscuous::AMQP::Fake.get_next_payload['dependencies']
        dep['link'].should  == nil
        # Mongoid does an extra count.
        dep['read'].should  == ["publisher_models:field_1:123:0",
                                "publisher_models:field_1:123:0"]
        dep['write'].should == nil
      end
    end

    context 'when using without_promiscuous.each' do
      it 'track the reads one by one' do
        pub1 = pub2 = nil
        without_promiscuous do
          pub1 = PublisherModel.create(:field_1 => 123)
          pub2 = PublisherModel.create(:field_1 => 123)
        end
        Promiscuous.transaction :active => true do
          expect do
            PublisherModel.all.without_promiscuous.where(:field_1 => 123).each do |p|
              p.reload
            end
          end.to_not raise_error
        end

        dep = Promiscuous::AMQP::Fake.get_next_payload['dependencies']
        dep['link'].should  == nil
        dep['read'].should  == ["publisher_models:id:#{pub1.id}:0",
                                "publisher_models:id:#{pub2.id}:0"]
        dep['write'].should == nil
      end
    end
  end
end
