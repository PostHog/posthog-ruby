require 'spec_helper'

class PostHog
    describe Utils do
        it 'size limited dict works' do
            size = 10
            dict = PostHog::Utils::SizeLimitedHash.new(size)
            for i in 0..100
                dict[i] = i

                expect(dict[i]).to eq(i)
                expect(dict.length).to eq(i % size + 1)

                if i % size == 0
                    # old numbers should've been removed
                    expect(dict[i-1]).to be_nil
                    expect(dict[i-3]).to be_nil
                    expect(dict[i-5]).to be_nil
                    expect(dict[i-9]).to be_nil
                end
            end
        end

        it 'size limited dict works with default block generator' do
            size = 10
            dict = PostHog::Utils::SizeLimitedHash.new(size) { |hash, key| hash[key] = Array.new }
            for i in 0..100
                dict[i] << i

                expect(dict[i]).to eq([i])
                expect(dict.length <= size).to eq(true)

            end
        end
    end
end