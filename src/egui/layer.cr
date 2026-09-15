# egui layering (layers.rs): a paint/interaction layer = Order + owner id
# + numeric z. Background = panels; Middle = windows; Foreground =
# popups/menus/modals; Tooltip = tooltips. Paint order, hit-test
# priority and hover occlusion all follow z — an Order is just a named
# default z (custom z is clamped into 0..MAX_LAYER_Z).

module Egui
  # The layer ceiling: every layer lives in [0, MAX_LAYER_Z].
  MAX_LAYER_Z = 100

  # Where dropdown menus, popups and modals ride — high enough to sit
  # above windows, one notch below the Tooltip ceiling.
  POPUP_LAYER_Z = 99

  enum Order
    Background
    Middle
    Foreground
    Tooltip

    # The Order's default z — the numeric layer a LayerId on this Order
    # sits at unless it was given an explicit z.
    def z : Int32
      case self
      in Background then 0
      in Middle    then 50
      in Foreground then POPUP_LAYER_Z
      in Tooltip   then MAX_LAYER_Z
      end
    end
  end

  struct LayerId
    getter order : Order
    getter id : Id
    # Numeric layer (0..MAX_LAYER_Z). Higher z paints later and wins
    # hit-tests; `order` remains for grouping rules (modal blocking,
    # popup close-on-outside-click).
    getter z : Int32

    def initialize(@order : Order, @id : Id, z : Int32? = nil)
      @z = (z || @order.z).clamp(0, MAX_LAYER_Z)
    end

    def self.background : LayerId
      new(Order::Background, Id.from("background"))
    end

    def ==(other : LayerId) : Bool
      order == other.order && id == other.id
    end

    def hash(hasher)
      hasher = order.value.hash(hasher)
      id.value.hash(hasher)
    end

    def inspect(io : IO) : Nil
      io << "LayerId(" << order << ", z=" << z << ")"
    end
  end
end
