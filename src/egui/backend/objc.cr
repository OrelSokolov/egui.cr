# Minimal Objective-C runtime layer for the macOS backend pieces
# (currently the system-tray adapter, tray_darwin.cr — ported from
# positron.cr's adapters/macos/objc.cr, trimmed to what the tray
# needs). egui.cr talks to AppKit through the ObjC runtime directly
# (objc_msgSend + dynamically registered classes), so no external
# bindings shard is needed.
#
# Crystal allows exactly ONE declaration per C symbol, so the layer is
# built on several dispatch paths:
#
#   * `ObjC.send*` — a single fixed-arity `objc_msgSend(recv, cmd, a1,
#     a2, a3)` declaration. Pointer, integer and bool arguments are
#     register-compatible with this shape (integers are passed as
#     `Pointer(Void).new(value)`); unused trailing arguments are NULL.
#     bool/NSInteger returns are reinterpreted from the id return.
#
#   * `ObjC.send_size` — `objc_msgSendSuper` with a typed NSSize
#     parameter for `setSize:`-style methods (HFA struct arguments
#     cannot go through NSInvocation on arm64).
#
#   * `ObjC::Call` — NSInvocation-based invocation for everything
#     else with non-HFA arguments: float arguments (the tray needs it
#     for `statusItemWithLength:`'s -1.0), 4+ arguments, and pointer
#     returns via `getReturnValue:`.

module Egui
  module Backend
    module ObjC
      extend self

      # --- Classes & selectors ---

      def cls(name : String) : Void*
        ptr = LibObjC.objc_getClass(name)
        raise "Objective-C class not found: #{name}" if ptr.null?
        ptr
      end

      def sel(name : String) : Void*
        LibObjC.sel_registerName(name)
      end

      # --- Fixed-arity message sends ---
      # Extra register arguments beyond the method's real signature
      # are ignored by the callee, so short calls just pass NULLs.

      def send0(recv : Void*, cmd : Void*) : Void*
        LibMsg.msg(recv, cmd, Pointer(Void).null, Pointer(Void).null, Pointer(Void).null, Pointer(Void).null)
      end

      def send1(recv : Void*, cmd : Void*, a1 : Void*) : Void*
        LibMsg.msg(recv, cmd, a1, Pointer(Void).null, Pointer(Void).null, Pointer(Void).null)
      end

      def send2(recv : Void*, cmd : Void*, a1 : Void*, a2 : Void*) : Void*
        LibMsg.msg(recv, cmd, a1, a2, Pointer(Void).null, Pointer(Void).null)
      end

      def send3(recv : Void*, cmd : Void*, a1 : Void*, a2 : Void*, a3 : Void*) : Void*
        LibMsg.msg(recv, cmd, a1, a2, a3, Pointer(Void).null)
      end

      # Pass an integer-sized value (NSInteger, NSUInteger, BOOL) as a
      # message argument.
      def int_arg(value : Int) : Void*
        Pointer(Void).new(value.to_u64!)
      end

      def bool_arg(value : Bool) : Void*
        int_arg(value ? 1 : 0)
      end

      # BOOL returns come back in the low byte of the id return.
      def send0_b(recv : Void*, cmd : Void*) : Bool
        (send0(recv, cmd).address & 0xFF) != 0
      end

      def send1_b(recv : Void*, cmd : Void*, a1 : Void*) : Bool
        (send1(recv, cmd, a1).address & 0xFF) != 0
      end

      # NSInteger/NSUInteger returns occupy the full return register.
      def send0_i(recv : Void*, cmd : Void*) : Int64
        send0(recv, cmd).address.to_i64
      end

      # Method dispatch with a typed NSSize argument (`setSize:`
      # family) — the `objc_msgSendSuper` path from the module docs.
      def send_size(receiver : Void*, selector : String, size : LibObjC::NSSize) : Void*
        super_ = LibSuper::ObjCSuper.new(
          receiver: receiver,
          cls: LibObjC.object_getClass(receiver))
        LibSuper.super_size(pointerof(super_), sel(selector), size)
      end

      # --- Bridging values ---

      # Autoreleased NSString (released by the pool drained each event
      # loop tick; wrap setup in `with_autorelease_pool`).
      def nsstr(s : String) : Void*
        send1(cls("NSString"), sel("stringWithUTF8String:"), s.to_unsafe.as(Void*))
      end

      def to_s(obj : Void*) : String?
        return nil if obj.null?
        cstr = send0(obj, sel("UTF8String"))
        cstr.null? ? nil : String.new(cstr.as(UInt8*))
      end

      # Autoreleased NSData copying `bytes`.
      def nsdata(bytes : Bytes) : Void*
        send2(cls("NSData"), sel("dataWithBytes:length:"),
          bytes.to_unsafe.as(Void*), int_arg(bytes.size))
      end

      # --- Autorelease pools ---
      # AppKit calls produce autoreleased objects; keep them bounded
      # by draining a pool around tray setup.

      def with_autorelease_pool(&)
        pool = send0(cls("NSAutoreleasePool"), sel("new"))
        begin
          yield
        ensure
          send0(pool, sel("drain"))
        end
      end

      # --- Dynamic classes for handler objects ---

      # Creates (or returns an already registered) ObjC class pair
      # deriving from `superclass`. Used to build target objects whose
      # methods are Crystal procs installed as IMPs.
      def new_class(name : String, superclass : String = "NSObject") : Void*
        existing = LibObjC.objc_getClass(name)
        return existing unless existing.null?
        new_cls = LibObjC.objc_allocateClassPair(cls(superclass), name, 0)
        raise "cannot allocate ObjC class #{name}" if new_cls.null?
        LibObjC.objc_registerClassPair(new_cls)
        new_cls
      end

      # Associate a native ObjC object with its Crystal adapter so IMP
      # callbacks (which only receive the ObjC receiver) can find the
      # adapter instance. The registry keeps the adapters alive, too.
      def bind_target(objc_obj : Void*, target : SystemPorts::Tray::Implementation) : Nil
        @@targets[objc_obj] = target
      end

      def target_for(objc_obj : Void*) : SystemPorts::Tray::Implementation?
        @@targets[objc_obj]?
      end

      @@targets = {} of Void* => SystemPorts::Tray::Implementation

      # A message send through NSInvocation — for signatures the fixed
      # `objc_msgSend` declaration cannot express: float arguments,
      # 4+ arguments.
      #
      #   call = ObjC::Call.new(receiver, "statusItemWithLength:")
      #     .double(2, -1.0)
      #     .invoke
      #     .ret_ptr
      class Call
        @invocation : Void*
        @signature : Void*

        def initialize(receiver : Void*, selector : String)
          @signature = ObjC.send1(receiver, ObjC.sel("methodSignatureForSelector:"), ObjC.sel(selector))
          raise "no method signature for #{selector} on #{receiver}" if @signature.null?
          @invocation = ObjC.send1(ObjC.cls("NSInvocation"), ObjC.sel("invocationWithMethodSignature:"), @signature)
          ObjC.send1(@invocation, ObjC.sel("setTarget:"), receiver)
          ObjC.send1(@invocation, ObjC.sel("setSelector:"), ObjC.sel(selector))
        end

        # Argument indices follow the ObjC convention: 0 = self,
        # 1 = _cmd, first real argument = 2.

        def ptr(index : Int32, value : Void*) : self
          ObjC.send2(@invocation, ObjC.sel("setArgument:atIndex:"), value, ObjC.int_arg(index))
          self
        end

        def int(index : Int32, value : Int64) : self
          buffer = Pointer(Int64).malloc(1)
          buffer.value = value
          ptr(index, buffer.as(Void*))
        end

        def double(index : Int32, value : Float64) : self
          buffer = Pointer(Float64).malloc(1)
          buffer.value = value
          ptr(index, buffer.as(Void*))
        end

        def invoke : self
          ObjC.send0(@invocation, ObjC.sel("invoke"))
          self
        end

        def ret_ptr : Void*
          buffer = Pointer(Void*).malloc(1)
          ObjC.send1(@invocation, ObjC.sel("getReturnValue:"), buffer.as(Void*))
          buffer.value
        end
      end

      # Objective-C runtime functions plus the C structs used by value.
      @[Link("objc")]
      lib LibObjC
        fun objc_getClass(name : LibC::Char*) : Void*
        fun sel_registerName(str : LibC::Char*) : Void*
        fun objc_allocateClassPair(superclass : Void*, name : LibC::Char*, extraBytes : Int32) : Void*
        fun objc_registerClassPair(cls : Void*) : Nil
        fun object_getClass(obj : Void*) : Void*
        fun class_addMethod(cls : Void*, name : Void*, imp : Void*, types : LibC::Char*) : UInt8

        struct NSSize
          width : Float64
          height : Float64
        end
      end

      # The single objc_msgSend declaration (see module docs). Pointer,
      # integer and bool arguments are all register-compatible; unused
      # trailing arguments must be NULL.
      @[Link("objc")]
      lib LibMsg
        fun msg = objc_msgSend(recv : Void*, cmd : Void*, a1 : Void*, a2 : Void*, a3 : Void*, a4 : Void*) : Void*
      end

      # Dispatch path for NSSize-by-value methods (`setSize:` family)
      # via objc_msgSendSuper with a typed NSSize parameter. The super
      # struct names the receiver's own class, so the method lookup
      # behaves like a normal send.
      @[Link("objc")]
      lib LibSuper
        struct ObjCSuper
          receiver : Void*
          cls : Void*
        end

        fun super_size = objc_msgSendSuper(super_ : ObjCSuper*, cmd : Void*, size : LibObjC::NSSize) : Void*
      end
    end
  end
end
