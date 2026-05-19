local base64 = require(script.Parent.base64)

local function identity(...)
	return ...
end

local function serializeFloat(value)
	-- TODO: Figure out a better way to serialize infinity and NaN, neither of
	-- which fit into JSON.
	if value == math.huge or value == -math.huge then
		return 999999999 * math.sign(value)
	end

	return value
end

-- Starfruit-Sync fork patch #46 (2026-05-19): the starfruit-sync-server's
-- wire format wraps every f32 as `{"$f32": <u32_bits>}` so the plugin can
-- reconstruct the exact bit pattern via buffer.readf32 (Lua's
-- HttpService.JSONDecode is not always IEEE-754 correctly-rounded for
-- 16-digit decimals, and CFrame.new's f64→f32 cast can then resolve to
-- a 1-ULP-off f32 bit pattern). Upstream rbx-dom-lua's geometric type
-- decoders (Color3 / Vector3 / CFrame / etc.) all expect plain Lua
-- numbers in their `pod`s. This helper recursively walks a decoded
-- table and unwraps any `{"$f32": bits}` it finds back to a Lua number.
--
-- Non-mutating (returns a new table when changes are needed; returns
-- the input value otherwise).
local function unwrapF32Wrappers(value)
	if type(value) ~= "table" then
		return value
	end
	if value["$f32"] ~= nil then
		local b = buffer.create(4)
		buffer.writeu32(b, 0, value["$f32"])
		return buffer.readf32(b, 0)
	end
	-- Walk children; only allocate a new table if at least one element
	-- actually needed unwrapping (saves GC pressure on the hot path).
	local result = nil
	for k, v in pairs(value) do
		local unwrapped = unwrapF32Wrappers(v)
		if unwrapped ~= v then
			if result == nil then
				result = {}
				for k2, v2 in pairs(value) do
					result[k2] = v2
				end
			end
			result[k] = unwrapped
		end
	end
	return result or value
end

local ALL_AXES = { "X", "Y", "Z" }
local ALL_FACES = { "Right", "Top", "Back", "Left", "Bottom", "Front" }

local EncodedValue = {}

local types
types = {
	Attributes = {
		fromPod = function(pod)
			local output = {}

			for key, value in pairs(pod) do
				local ok, result = EncodedValue.decode(value)

				if ok then
					output[key] = result
				else
					local warning = ("Could not decode attribute value of type %q: %s"):format(
						typeof(value),
						tostring(result)
					)
					warn(warning)
				end
			end

			return output
		end,
		toPod = function(roblox)
			local output = {}

			for key, value in pairs(roblox) do
				local ok, result = EncodedValue.encodeNaive(value)

				if ok then
					output[key] = result
				else
					local warning = ("Could not encode attribute value of type %q: %s"):format(
						typeof(value),
						tostring(result)
					)
					warn(warning)
				end
			end

			return output
		end,
	},

	Axes = {
		fromPod = function(pod)
			local axes = {}

			for index, axisName in ipairs(pod) do
				axes[index] = Enum.Axis[axisName]
			end

			return Axes.new(unpack(axes))
		end,

		toPod = function(roblox)
			local json = {}

			for _, axis in ipairs(ALL_AXES) do
				if roblox[axis] then
					table.insert(json, axis)
				end
			end

			return json
		end,
	},

	BinaryString = {
		fromPod = base64.decode,
		toPod = base64.encode,
	},

	Bool = {
		fromPod = identity,
		toPod = identity,
	},

	BrickColor = {
		fromPod = function(pod)
			return BrickColor.new(pod)
		end,

		toPod = function(roblox)
			return roblox.Number
		end,
	},

	CFrame = {
		-- Fork patch (2026-05-19): dual-shape decoder. Legacy rbxjson form
		-- is `{position: [x, y, z], orientation: [[r00..r02], [r10..r12],
		-- [r20..r22]]}` (3x3 array of arrays); starfruit-sync-server wire
		-- form is `{position: [x, y, z], rotation: [r00, r01, r02, r10,
		-- r11, r12, r20, r21, r22]}` (flat 9-element rotation array). Both
		-- shapes may have $f32-wrapped components, which we unwrap
		-- recursively first.
		fromPod = function(pod)
			pod = unwrapF32Wrappers(pod)
			local pos = pod.position

			if pod.rotation ~= nil then
				local r = pod.rotation
				--stylua: ignore
				return CFrame.new(
					pos[1], pos[2], pos[3],
					r[1], r[2], r[3],
					r[4], r[5], r[6],
					r[7], r[8], r[9]
				)
			else
				local orient = pod.orientation
				--stylua: ignore
				return CFrame.new(
					pos[1], pos[2], pos[3],
					orient[1][1], orient[1][2], orient[1][3],
					orient[2][1], orient[2][2], orient[2][3],
					orient[3][1], orient[3][2], orient[3][3]
				)
			end
		end,

		toPod = function(roblox)
			local x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22 = roblox:GetComponents()

			return {
				position = { x, y, z },
				orientation = {
					{ r00, r01, r02 },
					{ r10, r11, r12 },
					{ r20, r21, r22 },
				},
			}
		end,
	},

	Color3 = {
		-- Fork patch #46: dual-shape decoder. Legacy rbxjson form is
		-- `[r, g, b]` (array); starfruit-sync-server wire form is
		-- `{r: $f32, g: $f32, b: $f32}` (object with $f32-wrapped
		-- components). Unwrap any $f32 wrappers, then dispatch by
		-- detected shape.
		fromPod = function(pod)
			pod = unwrapF32Wrappers(pod)
			if pod.r ~= nil then
				return Color3.new(pod.r, pod.g, pod.b)
			else
				return Color3.new(pod[1], pod[2], pod[3])
			end
		end,

		toPod = function(roblox)
			return { roblox.r, roblox.g, roblox.b }
		end,
	},

	Color3uint8 = {
		-- Fork patch (2026-05-19): dual-shape decoder. Legacy rbxjson form
		-- is `[r, g, b]` (array of u8); starfruit-sync-server wire form is
		-- `{r: int, g: int, b: int}` (named-key bytes 0-255).
		fromPod = function(pod)
			if pod.r ~= nil then
				return Color3.fromRGB(pod.r, pod.g, pod.b)
			else
				return Color3.fromRGB(pod[1], pod[2], pod[3])
			end
		end,

		toPod = function(roblox)
			return {
				math.round(roblox.R * 255),
				math.round(roblox.G * 255),
				math.round(roblox.B * 255),
			}
		end,
	},

	ColorSequence = {
		fromPod = function(pod)
			local keypoints = {}

			for index, keypoint in ipairs(pod.keypoints) do
				keypoints[index] = ColorSequenceKeypoint.new(keypoint.time, types.Color3.fromPod(keypoint.color))
			end

			return ColorSequence.new(keypoints)
		end,

		toPod = function(roblox)
			local keypoints = {}

			for index, keypoint in ipairs(roblox.Keypoints) do
				keypoints[index] = {
					time = keypoint.Time,
					color = types.Color3.toPod(keypoint.Value),
				}
			end

			return {
				keypoints = keypoints,
			}
		end,
	},

	Content = {
		fromPod = function(pod): Content
			if type(pod) == "string" then
				if pod == "None" then
					return Content.none
				else
					error(`unexpected Content value '{pod}'`)
				end
			else
				local ty, value = next(pod)
				if ty == "Uri" then
					return Content.fromUri(value)
				elseif ty == "Object" then
					error("Object deserializing is not currently implemented")
				else
					error(`Unknown Content type '{ty}' (could not deserialize)`)
				end
			end
		end,
		toPod = function(roblox: Content)
			if roblox.SourceType == Enum.ContentSourceType.None then
				return "None"
			elseif roblox.SourceType == Enum.ContentSourceType.Uri then
				return { Uri = roblox.Uri }
			elseif roblox.SourceType == Enum.ContentSourceType.Object then
				error("Object serializing is not currently implemented")
			else
				error(`Unknown Content type '{roblox.SourceType} (could not serialize)`)
			end
		end,
	},

	ContentId = {
		fromPod = identity,
		toPod = identity,
	},

	Enum = {
		fromPod = identity,

		toPod = function(roblox)
			-- FIXME: More robust handling of enums
			if typeof(roblox) == "number" then
				return roblox
			else
				return roblox.Value
			end
		end,
	},

	EnumItem = {
		fromPod = function(pod)
			return Enum[pod.type]:FromValue(pod.value)
		end,

		toPod = function(roblox)
			return {
				type = tostring(roblox.EnumType),
				value = roblox.Value,
			}
		end,
	},

	Faces = {
		fromPod = function(pod)
			local faces = {}

			for index, faceName in ipairs(pod) do
				faces[index] = Enum.NormalId[faceName]
			end

			return Faces.new(unpack(faces))
		end,

		toPod = function(roblox)
			local pod = {}

			for _, face in ipairs(ALL_FACES) do
				if roblox[face] then
					table.insert(pod, face)
				end
			end

			return pod
		end,
	},

	Float32 = {
		-- Fork patch #46 (2026-05-19): the starfruit-sync-server emits
		-- f32 properties as `{"$f32": <u32_bits>}` wrappers for lossless
		-- bit-exact preservation (Lua HttpService.JSONDecode is not
		-- always IEEE-754 correctly-rounded for 16-digit decimals).
		-- unwrapF32Wrappers is a no-op on plain Lua numbers, so disk-form
		-- rbxjson (bare numbers) flows through unchanged. Wire-form
		-- ({"$f32": bits}) gets unwrapped via buffer.readf32.
		fromPod = unwrapF32Wrappers,
		toPod = serializeFloat,
	},

	Float64 = {
		-- Same dual-accept as Float32. Float64 doesn't typically need
		-- bit-exact preservation, but unwrapping is a safe no-op for
		-- plain numbers, so we apply uniformly.
		fromPod = unwrapF32Wrappers,
		toPod = serializeFloat,
	},

	-- Fork patch #46 (2026-05-19): also expose `$f32` as a `types`
	-- entry so the legacy single-arg EncodedValue.decode (used by the
	-- Attributes recursive decoder) also finds it via `next()` dispatch.
	-- This handles the case where a raw {"$f32": bits} table is passed
	-- without a dataType hint.
	["$f32"] = {
		fromPod = function(bits)
			local b = buffer.create(4)
			buffer.writeu32(b, 0, bits)
			return buffer.readf32(b, 0)
		end,
		toPod = function(_)
			error("$f32 is a wire-only form; encode via Float32 instead")
		end,
	},

	Font = {
		fromPod = function(pod)
			return Font.new(
				pod.family,
				if pod.weight ~= nil then Enum.FontWeight[pod.weight] else nil,
				if pod.style ~= nil then Enum.FontStyle[pod.style] else nil
			)
		end,
		toPod = function(roblox)
			return {
				family = roblox.Family,
				weight = roblox.Weight.Name,
				style = roblox.Style.Name,
			}
		end,
	},

	Int32 = {
		fromPod = identity,
		toPod = identity,
	},

	Int64 = {
		fromPod = identity,
		toPod = identity,
	},

	MaterialColors = {
		fromPod = function(pod: { [string]: { number } })
			local real = {}
			for name, color in pod do
				real[Enum.Material[name]] = Color3.fromRGB(color[1], color[2], color[3])
			end
			return real
		end,
		toPod = function(roblox: { [Enum.Material]: Color3 })
			local pod = {}
			for material, color in roblox do
				pod[material.Name] = {
					math.round(math.clamp(color.R, 0, 1) * 255),
					math.round(math.clamp(color.G, 0, 1) * 255),
					math.round(math.clamp(color.B, 0, 1) * 255),
				}
			end
			return pod
		end,
	},

	NumberRange = {
		-- Fork patch (2026-05-19): dual-shape decoder. Legacy rbxjson form
		-- is `[min, max]` (array); starfruit-sync-server wire form is
		-- `{min: $f32, max: $f32}` (named-key with $f32-wrapped components).
		fromPod = function(pod)
			pod = unwrapF32Wrappers(pod)
			if pod.min ~= nil then
				return NumberRange.new(pod.min, pod.max)
			else
				return NumberRange.new(pod[1], pod[2])
			end
		end,

		toPod = function(roblox)
			return { roblox.Min, roblox.Max }
		end,
	},

	NumberSequence = {
		fromPod = function(pod)
			local keypoints = {}

			for index, keypoint in ipairs(pod.keypoints) do
				-- TODO: Add a test for NaN or Infinity values and envelopes
				-- Right now it isn't possible because it'd fail the roundtrip.
				-- It's more important that it works right now, though.
				local value = keypoint.value or 0
				local envelope = keypoint.envelope or 0
				keypoints[index] = NumberSequenceKeypoint.new(keypoint.time, value, envelope)
			end

			return NumberSequence.new(keypoints)
		end,

		toPod = function(roblox)
			local keypoints = {}

			for index, keypoint in ipairs(roblox.Keypoints) do
				keypoints[index] = {
					time = keypoint.Time,
					value = keypoint.Value,
					envelope = keypoint.Envelope,
				}
			end

			return {
				keypoints = keypoints,
			}
		end,
	},

	PhysicalProperties = {
		fromPod = function(pod)
			if pod == "Default" then
				return nil
			else
				-- Fork patch #46 (2026-05-19): unwrap any $f32 wrappers
				-- recursively + handle Rust wire form `{custom: {density,
				-- friction, ...}}` vs legacy rbxjson `{density, friction,
				-- ...}` direct form. Both shapes encountered in production.
				pod = unwrapF32Wrappers(pod)
				if pod.custom then
					pod = pod.custom
				end
				-- Passing `nil` instead of not passing anything gives
				-- different results, so we have to branch here.
				if pod.acousticAbsorption then
					return (PhysicalProperties.new :: any)(
						pod.density,
						pod.friction,
						pod.elasticity,
						pod.frictionWeight,
						pod.elasticityWeight,
						pod.acousticAbsorption
					)
				else
					return PhysicalProperties.new(
						pod.density,
						pod.friction,
						pod.elasticity,
						pod.frictionWeight,
						pod.elasticityWeight
					)
				end
			end
		end,

		toPod = function(roblox)
			if roblox == nil then
				return "Default"
			else
				return {
					density = roblox.Density,
					friction = roblox.Friction,
					elasticity = roblox.Elasticity,
					frictionWeight = roblox.FrictionWeight,
					elasticityWeight = roblox.ElasticityWeight,
					acousticAbsorption = roblox.AcousticAbsorption,
				}
			end
		end,
	},

	Ray = {
		fromPod = function(pod)
			return Ray.new(types.Vector3.fromPod(pod.origin), types.Vector3.fromPod(pod.direction))
		end,

		toPod = function(roblox)
			return {
				origin = types.Vector3.toPod(roblox.Origin),
				direction = types.Vector3.toPod(roblox.Direction),
			}
		end,
	},

	Rect = {
		-- Fork patch (2026-05-19): dual-shape decoder. Legacy rbxjson form
		-- is `[[x, y], [x, y]]` (array of arrays); starfruit-sync-server
		-- wire form is `{min: {x, y}, max: {x, y}}` (named-key Vector2s,
		-- each itself dual-shape via types.Vector2.fromPod).
		fromPod = function(pod)
			if pod.min ~= nil then
				return Rect.new(types.Vector2.fromPod(pod.min), types.Vector2.fromPod(pod.max))
			else
				return Rect.new(types.Vector2.fromPod(pod[1]), types.Vector2.fromPod(pod[2]))
			end
		end,

		toPod = function(roblox)
			return {
				types.Vector2.toPod(roblox.Min),
				types.Vector2.toPod(roblox.Max),
			}
		end,
	},

	Ref = {
		fromPod = function(_)
			error("Ref cannot be decoded on its own")
		end,

		toPod = function(_)
			error("Ref can not be encoded on its own")
		end,
	},

	Region3 = {
		fromPod = function(_)
			error("Region3 is not implemented")
		end,

		toPod = function(_)
			error("Region3 is not implemented")
		end,
	},

	Region3int16 = {
		-- Fork patch (2026-05-19): dual-shape decoder. Legacy rbxjson form
		-- is `[[x,y,z], [x,y,z]]` (array of arrays); starfruit-sync-server
		-- wire form is `{min: {x,y,z}, max: {x,y,z}}` (named-key
		-- Vector3int16s, each itself dual-shape).
		fromPod = function(pod)
			if pod.min ~= nil then
				return Region3int16.new(types.Vector3int16.fromPod(pod.min), types.Vector3int16.fromPod(pod.max))
			else
				return Region3int16.new(types.Vector3int16.fromPod(pod[1]), types.Vector3int16.fromPod(pod[2]))
			end
		end,

		toPod = function(roblox)
			return {
				types.Vector3int16.toPod(roblox.Min),
				types.Vector3int16.toPod(roblox.Max),
			}
		end,
	},

	SharedString = {
		fromPod = function(_pod)
			error("SharedString is not supported")
		end,

		toPod = function(_roblox)
			error("SharedString is not supported")
		end,
	},

	String = {
		fromPod = identity,
		toPod = identity,
	},

	UDim = {
		-- Fork patch (2026-05-19): dual-shape decoder. Legacy rbxjson form
		-- is `[scale, offset]` (array); starfruit-sync-server wire form is
		-- `{scale: $f32, offset: int}` (object with $f32-wrapped scale +
		-- bare integer offset).
		fromPod = function(pod)
			pod = unwrapF32Wrappers(pod)
			if pod.scale ~= nil then
				return UDim.new(pod.scale, pod.offset)
			else
				return UDim.new(pod[1], pod[2])
			end
		end,

		toPod = function(roblox)
			return { roblox.Scale, roblox.Offset }
		end,
	},

	UDim2 = {
		-- Fork patch (2026-05-19): dual-shape decoder. Legacy rbxjson form
		-- is `[[scale, offset], [scale, offset]]` (array of arrays);
		-- starfruit-sync-server wire form is `{x: {scale, offset}, y:
		-- {scale, offset}}` (named-key UDims). Each component UDim is
		-- decoded through `types.UDim.fromPod`, which itself accepts
		-- both shapes.
		fromPod = function(pod)
			pod = unwrapF32Wrappers(pod)
			if pod.x ~= nil then
				return UDim2.new(types.UDim.fromPod(pod.x), types.UDim.fromPod(pod.y))
			else
				return UDim2.new(types.UDim.fromPod(pod[1]), types.UDim.fromPod(pod[2]))
			end
		end,

		toPod = function(roblox)
			return {
				types.UDim.toPod(roblox.X),
				types.UDim.toPod(roblox.Y),
			}
		end,
	},

	Tags = {
		fromPod = identity,
		toPod = identity,
	},

	Vector2 = {
		-- Fork patch #46: dual-shape decoder.
		fromPod = function(pod)
			pod = unwrapF32Wrappers(pod)
			if pod.x ~= nil then
				return Vector2.new(pod.x, pod.y)
			else
				return Vector2.new(pod[1], pod[2])
			end
		end,

		toPod = function(roblox)
			return {
				serializeFloat(roblox.X),
				serializeFloat(roblox.Y),
			}
		end,
	},

	Vector2int16 = {
		-- Fork patch (2026-05-19): dual-shape decoder. Legacy rbxjson form
		-- is `[x, y]` (array); starfruit-sync-server wire form is
		-- `{x: int, y: int}` (named-key i16 components).
		fromPod = function(pod)
			if pod.x ~= nil then
				return Vector2int16.new(pod.x, pod.y)
			else
				return Vector2int16.new(pod[1], pod[2])
			end
		end,

		toPod = function(roblox)
			return { roblox.X, roblox.Y }
		end,
	},

	Vector3 = {
		-- Fork patch #46: dual-shape decoder. Legacy rbxjson form is
		-- `[x, y, z]` (array); starfruit-sync-server wire form is
		-- `{x: $f32, y: $f32, z: $f32}` (object).
		fromPod = function(pod)
			pod = unwrapF32Wrappers(pod)
			if pod.x ~= nil then
				return Vector3.new(pod.x, pod.y, pod.z)
			else
				return Vector3.new(pod[1], pod[2], pod[3])
			end
		end,

		toPod = function(roblox)
			return {
				serializeFloat(roblox.X),
				serializeFloat(roblox.Y),
				serializeFloat(roblox.Z),
			}
		end,
	},

	Vector3int16 = {
		-- Fork patch (2026-05-19): dual-shape decoder. Legacy rbxjson form
		-- is `[x, y, z]` (array); starfruit-sync-server wire form is
		-- `{x: int, y: int, z: int}` (named-key i16 components).
		fromPod = function(pod)
			if pod.x ~= nil then
				return Vector3int16.new(pod.x, pod.y, pod.z)
			else
				return Vector3int16.new(pod[1], pod[2], pod[3])
			end
		end,

		toPod = function(roblox)
			return { roblox.X, roblox.Y, roblox.Z }
		end,
	},
}

types.OptionalCFrame = {
	fromPod = function(pod)
		if pod == nil then
			return nil
		else
			return types.CFrame.fromPod(pod)
		end
	end,

	toPod = function(roblox)
		if roblox == nil then
			return nil
		else
			return types.CFrame.toPod(roblox)
		end
	end,
}

-- Fork patch #46 (2026-05-19): types["Enum"] handles starfruit-sync-server
-- wire form `{enumType: "Name", value: "ItemName"}` (or numeric fallback).
-- Upstream rbx-dom-lua doesn't have an "Enum" entry — enums are typically
-- decoded by the consumer (e.g. SyncAdapter's decodeVariant). Adding this
-- entry means the dataType-aware decode path below can dispatch to it.
types.Enum = {
	fromPod = function(pod)
		if type(pod) == "table" and pod.enumType ~= nil then
			local enumByType = Enum[pod.enumType]
			if enumByType ~= nil then
				local item = enumByType[pod.value]
				if item ~= nil then return item end
				-- Numeric value fallback
				if type(pod.value) == "number" then
					for _, e in ipairs(enumByType:GetEnumItems()) do
						if e.Value == pod.value then return e end
					end
				end
			end
			return nil
		elseif type(pod) == "number" then
			-- Numeric-only wire form — caller must know the enum type
			-- from descriptor.dataType to map this. Return as-is and
			-- let raw-bracket assignment do the int → Enum coercion.
			return pod
		end
		return pod
	end,
	toPod = function(roblox)
		return { enumType = tostring(roblox.EnumType), value = roblox.Name }
	end,
}

function EncodedValue.decode(encodedValue, dataType)
	-- Fork patch #46 (2026-05-19): dataType-aware dispatch for the
	-- starfruit-sync-server wire shape (no `{TypeName = pod}` envelope;
	-- the pod is at the top level). Caller passes `descriptor.dataType`
	-- from rbx-dom-lua's reflection database — typically
	-- `{Value = "Float32"}` or `{Enum = "ReverbType"}`.
	--
	-- Without this path, `next(encodedValue)` fails for:
	--   - Booleans (throws "table expected, got boolean")
	--   - `{"$f32": bits}` wrappers (now handled via types["$f32"] entry)
	--   - Enum `{enumType, value}` (next() returns first key, not type name)
	--   - Geometric types with named-key shapes (Vector3 {x, y, z}, etc.)
	--
	-- With the hint, we dispatch directly to the typeImpl and call its
	-- fromPod with the raw pod (the geometric type's fromPod now handles
	-- both array and object shapes — see Color3/Vector3/Vector2 patches).
	if dataType ~= nil then
		local hintedName = nil
		if type(dataType) == "string" then
			-- PropertyDescriptor.fromRaw exposes dataType as a STRING:
			-- "Bool", "Float32", "Color3", "Enum" (for Enums it loses
			-- the specific enum-type name — types.Enum.fromPod
			-- recovers it from the pod's `enumType` field on the
			-- starfruit wire form).
			hintedName = dataType
		elseif type(dataType) == "table" then
			-- Raw rbx-dom-database shape: {Value = "Bool"} or {Enum = "X"}.
			-- Some callers may pass the raw shape rather than the
			-- PropertyDescriptor-extracted string.
			if dataType.Value ~= nil then
				hintedName = dataType.Value
			elseif dataType.Enum ~= nil then
				hintedName = "Enum"
			end
		end
		if hintedName ~= nil then
			local typeImpl = types[hintedName]
			if typeImpl ~= nil then
				local ok, result = pcall(typeImpl.fromPod, encodedValue)
				if ok then return true, result end
				return false, tostring(result)
			end
			-- Fall through to legacy path if no type impl (extensible)
		end
	end

	-- Legacy 1-arg form: rbx-dom-lua's `{TypeName = pod}` envelope shape.
	-- For booleans / primitives this branch fails (next() throws on
	-- non-tables) — callers using the wire shape MUST pass dataType.
	if type(encodedValue) ~= "table" then
		return false, "Couldn't decode value " .. tostring(encodedValue)
			.. " (primitive value requires dataType hint)"
	end
	local ty, value = next(encodedValue)

	if ty == nil then
		-- If the encoded pair is empty, assume it is an unoccupied optional value
		return true, nil
	end

	local typeImpl = types[ty]
	if typeImpl == nil then
		return false, "Couldn't decode value " .. tostring(ty)
	end

	return true, typeImpl.fromPod(value)
end

function EncodedValue.encode(rbxValue, propertyType)
	assert(propertyType ~= nil, "Property type descriptor is required")

	local typeImpl = types[propertyType]
	if typeImpl == nil then
		return false, ("Missing encoder for property type %q"):format(propertyType)
	end

	return true, {
		[propertyType] = typeImpl.toPod(rbxValue),
	}
end

local propertyTypeRenames = {
	number = "Float64",
	boolean = "Bool",
	string = "String",
}

function EncodedValue.encodeNaive(rbxValue)
	local propertyType = typeof(rbxValue)
	if propertyTypeRenames[propertyType] ~= nil then
		propertyType = propertyTypeRenames[propertyType]
	end

	return EncodedValue.encode(rbxValue, propertyType)
end

return EncodedValue
