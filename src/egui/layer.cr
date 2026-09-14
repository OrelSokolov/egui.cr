# egui layering (layers.rs): a paint/interaction layer = Order + owner id.
# Background = panels; Middle = windows; Foreground = popups/menus;
# Tooltip = tooltips. Paint order and hit-test priority follow Order.

module Egui
  enum Order
    Background
    Middle
    Foreground
    Tooltip
  end

  struct LayerId
    getter order : Order
    getter id : Id

    def initialize(@order : Order, @id : Id)
    end

    def self.background : LayerId
      new(Order::Background, Id.from("background"))
    end

    def ==(other : LayerId) : Bool
      order == other.order && id == other.id
    end

    def hash(hasher)
      hasher.int(order.value)
      hasher.uint(id.value)
    end

    def inspect(io : IO) : Nil
      io << "LayerId(" << order << ")"
    end
  end
end
