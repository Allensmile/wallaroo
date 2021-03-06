/*

Copyright (C) 2016-2017, Wallaroo Labs
Copyright (C) 2016-2017, The Pony Developers
Copyright (c) 2014-2015, Causality Ltd.
All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

1. Redistributions of source code must retain the above copyright notice, this
   list of conditions and the following disclaimer.
2. Redistributions in binary form must reproduce the above copyright notice,
   this list of conditions and the following disclaimer in the documentation
   and/or other materials provided with the distribution.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS "AS IS" AND
ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED TO, THE IMPLIED
WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR PURPOSE ARE
DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT OWNER OR CONTRIBUTORS BE LIABLE FOR
ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES
(INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES;
LOSS OF USE, DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND
ON ANY THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE OF THIS
SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.

*/

use "collections"
use "wallaroo/core/boundary"
use "wallaroo/core/common"
use "wallaroo/ent/data_receiver"
use "wallaroo/ent/recovery"
use "wallaroo/ent/router_registry"
use "wallaroo_labs/mort"
use "wallaroo/core/initialization"
use "wallaroo/core/metrics"
use "wallaroo/core/routing"
use "wallaroo/core/sink/tcp_sink"
use "wallaroo/core/source"
use "wallaroo/core/topology"

actor TCPSourceListener is SourceListener
  """
  # TCPSourceListener
  """

  let _router: Router
  let _router_registry: RouterRegistry
  let _route_builder: RouteBuilder
  let _default_in_route_builder: (RouteBuilder | None)
  var _outgoing_boundary_builders: Map[String, OutgoingBoundaryBuilder] val
  let _layout_initializer: LayoutInitializer
  let _default_target: (Step | None)
  var _fd: U32
  var _event: AsioEventID = AsioEvent.none()
  let _limit: USize
  var _count: USize = 0
  var _closed: Bool = false
  var _init_size: USize
  var _max_size: USize
  let _metrics_reporter: MetricsReporter
  var _source_builder: SourceBuilder
  let _event_log: EventLog
  let _auth: AmbientAuth
  let _target_router: Router

  new create(source_builder: SourceBuilder, router: Router,
    router_registry: RouterRegistry, route_builder: RouteBuilder,
    outgoing_boundary_builders: Map[String, OutgoingBoundaryBuilder] val,
    event_log: EventLog, auth: AmbientAuth,
    layout_initializer: LayoutInitializer,
    metrics_reporter: MetricsReporter iso,
    default_target: (Step | None) = None,
    default_in_route_builder: (RouteBuilder | None) = None,
    target_router: Router = EmptyRouter,
    host: String = "", service: String = "0", limit: USize = 0,
    init_size: USize = 64, max_size: USize = 16384)
  =>
    """
    Listens for both IPv4 and IPv6 connections.
    """
    _router = router
    _router_registry = router_registry
    _route_builder = route_builder
    _default_in_route_builder = default_in_route_builder
    _outgoing_boundary_builders = outgoing_boundary_builders
    _layout_initializer = layout_initializer
    _event = @pony_os_listen_tcp[AsioEventID](this,
      host.cstring(), service.cstring())
    _limit = limit
    _default_target = default_target
    _metrics_reporter = consume metrics_reporter
    _source_builder = source_builder
    _event_log = event_log
    _auth = auth
    _target_router = target_router

    _init_size = init_size
    _max_size = max_size
    _fd = @pony_asio_event_fd(_event)
    @printf[I32]((source_builder.name() + " source attempting to listen on "
      + host + ":" + service + "\n").cstring())
    _notify_listening()

  be update_router(router: PartitionRouter) =>
    _source_builder = _source_builder.update_router(router)

  be remove_route_for(moving_step: Consumer) =>
    None

  be add_boundary_builders(
    boundary_builders: Map[String, OutgoingBoundaryBuilder] val)
  =>
    let new_builders = recover trn Map[String, OutgoingBoundaryBuilder] end
    // TODO: A persistent map on the field would be much more efficient here
    for (target_worker_name, builder) in _outgoing_boundary_builders.pairs() do
      new_builders(target_worker_name) = builder
    end
    for (target_worker_name, builder) in boundary_builders.pairs() do
      if not new_builders.contains(target_worker_name) then
        new_builders(target_worker_name) = builder
      end
    end
    _outgoing_boundary_builders = consume new_builders

  be dispose() =>
    @printf[I32]("Shutting down TCPSourceListener\n".cstring())
    _close()

  be _event_notify(event: AsioEventID, flags: U32, arg: U32) =>
    """
    When we are readable, we accept new connections until none remain.
    """
    if event isnt _event then
      return
    end

    if AsioEvent.readable(flags) then
      _accept(arg)
    end

    if AsioEvent.disposable(flags) then
      @pony_asio_event_destroy(_event)
      _event = AsioEvent.none()
    end

  be _conn_closed() =>
    """
    An accepted connection has closed. If we have dropped below the limit, try
    to accept new connections.
    """
    _count = _count - 1

    if _count < _limit then
      _accept()
    end

  fun ref _accept(ns: U32 = 0) =>
    """
    Accept connections as long as we have spawned fewer than our limit.
    """
    if _closed then
      return
    end

    while (_limit == 0) or (_count < _limit) do
      var fd = @pony_os_accept[U32](_event)

      match fd
      | -1 =>
        // Something other than EWOULDBLOCK, try again.
        None
      | 0 =>
        // EWOULDBLOCK, don't try again.
        return
      else
        _spawn(fd)
      end
    end

  fun ref _spawn(ns: U32) =>
    """
    Spawn a new connection.
    """
    try
      let source = TCPSource._accept(this, _notify_connected(),
        _router.routes(), _route_builder, _outgoing_boundary_builders,
        _layout_initializer, ns, _default_target,
        _default_in_route_builder, _init_size, _max_size,
        _metrics_reporter.clone(), _router_registry)
      // TODO: We need to figure out how to unregister this when the
      // connection dies
      _router_registry.register_source(source)
      _count = _count + 1
    else
      @pony_os_socket_close[None](ns)
    end

  fun ref _notify_listening() =>
    """
    Inform the notifier that we're listening.
    """
    if not _event.is_null() then
      @printf[I32]((_source_builder.name() + " source is listening\n").cstring())
    else
      _closed = true
      @printf[I32]((_source_builder.name() +
        " source is unable to listen\n").cstring())
      Fail()
    end

  fun ref _notify_connected(): TCPSourceNotify iso^ ? =>
    try
      _source_builder(_event_log, _auth, _target_router)
        as TCPSourceNotify iso^
    else
      @printf[I32](
        (_source_builder.name() + " could not create a TCPSourceNotify\n").cstring())
      Fail()
      error
    end

  fun ref _close() =>
    """
    Dispose of resources.
    """
    if _closed then
      return
    end

    _closed = true

    if not _event.is_null() then
      @pony_os_socket_close[None](_fd)
      _fd = -1

      // When not on windows, the unsubscribe is done immediately.
      ifdef not windows then
        @pony_asio_event_unsubscribe(_event)
      end
    end
