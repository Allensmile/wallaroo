# Copyright 2017 The Wallaroo Authors.
#
#  Licensed under the Apache License, Version 2.0 (the "License");
#  you may not use this file except in compliance with the License.
#  You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
#  Unless required by applicable law or agreed to in writing, software
#  distributed under the License is distributed on an "AS IS" BASIS,
#  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or
#  implied. See the License for the specific language governing
#  permissions and limitations under the License.


import struct

import wallaroo


def application_setup(args):
    (in_topic, in_brokers,
     in_log_level) = wallaroo.kafka_parse_source_options(args)

    (out_topic, out_brokers, out_log_level, out_max_produce_buffer_ms,
     out_max_message_size) = wallaroo.kafka_parse_sink_options(args)

    ab = wallaroo.ApplicationBuilder("Celsius to Fahrenheit with Kafka")

    ab.new_pipeline("convert",
                    wallaroo.KafkaSourceConfig(in_topic, in_brokers, in_log_level,
                                               Decoder()))

    ab.to(Multiply)
    ab.to(Add)

    ab.to_sink(wallaroo.KafkaSinkConfig(out_topic, out_brokers, out_log_level,
                                        out_max_produce_buffer_ms,
                                        out_max_message_size,
                                        Encoder()))
    return ab.build()


class Decoder(object):
    def decode(self, bs):
        if len(bs) < 4:
          return 0.0
        return struct.unpack('>f', bs[:4])[0]

class Multiply(object):
    def name(self):
        return "multiply by 1.8"

    def compute(self, data):
        return data * 1.8


class Add(object):
    def name(self):
        return "add 32"

    def compute(self, data):
        return data + 32


class Encoder(object):
    def encode(self, data):
        # data is a float
        return (struct.pack('>f', data), None)
