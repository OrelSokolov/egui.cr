# 3D math for Viewport3D — Vec3 and a column-major Mat4 with a Float32
# backing so a matrix can be handed to the backend shim (egui_cr_mesh3d)
# without conversion. `math.cr` stays 2D-only; the two files are separate
# on purpose.

module Egui
  struct Vec3
    property x : Float64
    property y : Float64
    property z : Float64

    def initialize(@x = 0.0, @y = 0.0, @z = 0.0)
    end

    def self.zero : Vec3
      Vec3.new(0.0, 0.0, 0.0)
    end

    def self.up : Vec3
      Vec3.new(0.0, 1.0, 0.0)
    end

    def +(other : Vec3) : Vec3
      Vec3.new(x + other.x, y + other.y, z + other.z)
    end

    def -(other : Vec3) : Vec3
      Vec3.new(x - other.x, y - other.y, z - other.z)
    end

    def *(s : Float64) : Vec3
      Vec3.new(x * s, y * s, z * s)
    end

    def *(s : Int32) : Vec3
      self * s.to_f64
    end

    def dot(other : Vec3) : Float64
      x * other.x + y * other.y + z * other.z
    end

    def cross(other : Vec3) : Vec3
      Vec3.new(y * other.z - z * other.y,
               z * other.x - x * other.z,
               x * other.y - y * other.x)
    end

    def length : Float64
      Math.sqrt(dot(self))
    end

    def normalized : Vec3
      l = length
      return Vec3.zero if l < 1e-12
      self * (1.0 / l)
    end

    def lerp(other : Vec3, t : Float64) : Vec3
      self + (other - self) * t
    end

    def inspect(io : IO) : Nil
      io << "Vec3(" << x << ", " << y << ", " << z << ")"
    end
  end

  # Column-major 4×4 matrix (`m[col][row]`, OpenGL layout — exactly what
  # sgl_load_matrix and egui_cr_mesh3d expect).
  struct Mat4
    @m : StaticArray(Float32, 16)

    def initialize
      @m = StaticArray(Float32, 16).new(0.0f32)
      @m[0] = 1.0f32
      @m[5] = 1.0f32
      @m[10] = 1.0f32
      @m[15] = 1.0f32
    end

    def self.identity : Mat4
      Mat4.new
    end

    def self.zero : Mat4
      mat = allocate
      mat.set_zero
      mat
    end

    protected def set_zero : Nil
      @m.fill(0.0f32)
    end

    def [](col : Int32, row : Int32) : Float32
      @m[col * 4 + row]
    end

    def []=(col : Int32, row : Int32, v : Float32) : Nil
      @m[col * 4 + row] = v
    end

    # Raw column-major floats for the shim.
    def to_unsafe : Pointer(Float32)
      @m.to_unsafe
    end

    def ==(other : Mat4) : Bool
      16.times { |i| return false unless @m[i] == other.to_unsafe[i] }
      true
    end

    # Matrix product self × other (apply `other` FIRST in world space).
    def *(other : Mat4) : Mat4
      out = Mat4.zero
      4.times do |c|
        4.times do |r|
          sum = 0.0f32
          4.times { |k| sum += self[k, r] * other[c, k] }
          out[c, r] = sum
        end
      end
      out
    end

    # Transform a point (w = 1, perspective divide included).
    def transform(v : Vec3) : Vec3
      x = self[0, 0].to_f64 * v.x + self[1, 0].to_f64 * v.y +
          self[2, 0].to_f64 * v.z + self[3, 0].to_f64
      y = self[0, 1].to_f64 * v.x + self[1, 1].to_f64 * v.y +
          self[2, 1].to_f64 * v.z + self[3, 1].to_f64
      z = self[0, 2].to_f64 * v.x + self[1, 2].to_f64 * v.y +
          self[2, 2].to_f64 * v.z + self[3, 2].to_f64
      w = self[0, 3].to_f64 * v.x + self[1, 3].to_f64 * v.y +
          self[2, 3].to_f64 * v.z + self[3, 3].to_f64
      return Vec3.zero if w.abs < 1e-12
      Vec3.new(x / w, y / w, z / w)
    end

    # Right-handed perspective projection (GL conventions: camera looks
    # down −z, NDC y up — sgl's origin_top_left viewport maps that to the
    # screen as expected).
    def self.perspective(fov_y_deg : Float64, aspect : Float64,
                         near : Float64, far : Float64) : Mat4
      f = 1.0 / Math.tan(fov_y_deg * Math::PI / 360.0)
      nf = 1.0 / (near - far)
      out = Mat4.zero
      out[0, 0] = (f / aspect).to_f32
      out[1, 1] = f.to_f32
      out[2, 2] = ((far + near) * nf).to_f32
      out[2, 3] = (-1.0f32)
      out[3, 2] = ((2.0 * far * near) * nf).to_f32
      out
    end

    def self.ortho(l : Float64, r : Float64, b : Float64, t : Float64,
                   n : Float64, f : Float64) : Mat4
      out = Mat4.zero
      out[0, 0] = (2.0 / (r - l)).to_f32
      out[1, 1] = (2.0 / (t - b)).to_f32
      out[2, 2] = (-2.0 / (f - n)).to_f32
      out[3, 0] = (-(r + l) / (r - l)).to_f32
      out[3, 1] = (-(t + b) / (t - b)).to_f32
      out[3, 2] = (-(f + n) / (f - n)).to_f32
      out[3, 3] = 1.0f32
      out
    end

    # Right-handed look-at view matrix.
    def self.look_at(eye : Vec3, target : Vec3, up : Vec3) : Mat4
      fz = (eye - target).normalized # forward (camera looks down -z)
      fx = up.cross(fz).normalized   # right
      fy = fz.cross(fx)             # up
      out = Mat4.identity
      out[0, 0] = fx.x.to_f32
      out[0, 1] = fx.y.to_f32
      out[0, 2] = fx.z.to_f32
      out[1, 0] = fy.x.to_f32
      out[1, 1] = fy.y.to_f32
      out[1, 2] = fy.z.to_f32
      out[2, 0] = fz.x.to_f32
      out[2, 1] = fz.y.to_f32
      out[2, 2] = fz.z.to_f32
      out[3, 0] = (-fx.dot(eye)).to_f32
      out[3, 1] = (-fy.dot(eye)).to_f32
      out[3, 2] = (-fz.dot(eye)).to_f32
      out
    end

    def self.translate(x : Float64, y : Float64, z : Float64) : Mat4
      out = Mat4.identity
      out[3, 0] = x.to_f32
      out[3, 1] = y.to_f32
      out[3, 2] = z.to_f32
      out
    end

    def self.scale(x : Float64, y : Float64, z : Float64) : Mat4
      out = Mat4.zero
      out[0, 0] = x.to_f32
      out[1, 1] = y.to_f32
      out[2, 2] = z.to_f32
      out[3, 3] = 1.0f32
      out
    end

    # Rotation by `radians` around the +y axis (world up).
    def self.rotate_y(radians : Float64) : Mat4
      c = Math.cos(radians)
      s = Math.sin(radians)
      out = Mat4.identity
      out[0, 0] = c.to_f32
      out[0, 2] = (-s).to_f32
      out[2, 0] = s.to_f32
      out[2, 2] = c.to_f32
      out
    end

    # Rotation by `radians` around the +x axis.
    def self.rotate_x(radians : Float64) : Mat4
      c = Math.cos(radians)
      s = Math.sin(radians)
      out = Mat4.identity
      out[1, 1] = c.to_f32
      out[1, 2] = s.to_f32
      out[2, 1] = (-s).to_f32
      out[2, 2] = c.to_f32
      out
    end

    # Rotation by `radians` around the +z axis.
    def self.rotate_z(radians : Float64) : Mat4
      c = Math.cos(radians)
      s = Math.sin(radians)
      out = Mat4.identity
      out[0, 0] = c.to_f32
      out[0, 1] = s.to_f32
      out[1, 0] = (-s).to_f32
      out[1, 1] = c.to_f32
      out
    end

    def inspect(io : IO) : Nil
      io << "Mat4("
      4.times do |r|
        io << "; " if r > 0
        4.times do |c|
          io << " " if c > 0
          io << self[c, r]
        end
      end
      io << ")"
    end
  end
end
