#include "byte_swap.hlsli"
#include "edram_load_store.hlsli"
#include "texture_address.hlsli"

[numthreads(20, 16, 1)]
void main(uint3 xe_group_id : SV_GroupID,
          uint3 xe_group_thread_id : SV_GroupThreadID,
          uint3 xe_thread_id : SV_DispatchThreadID) {
  // 1 group = 80x16 destination (with resolution scale applied) pixels.
  // 1 thread = 4 destination pixels.

  uint4 sample_count_and_scale_info = XeEDRAMSampleCountAndScaleInfo();

  // Check if the whole thread is not out of the rectangle's Y bounds, and if X
  // coordinates in the thread are inside the rectangle's X bounds.
  uint2 dispatch_pixel_index_unscaled =
      (xe_thread_id.xy >> sample_count_and_scale_info.z) * uint2(4u, 1u);
  uint2 source_rect_unscaled_tl = xe_edram_tile_sample_dimensions >> 20u;
  uint2 source_rect_unscaled_br =
      source_rect_unscaled_tl + (xe_edram_tile_sample_dimensions & 0xFFFu);
  uint4 dispatch_pixel_x_coords_unscaled =
      dispatch_pixel_index_unscaled.x + uint4(0u, 1u, 2u, 3u);
  bool4 x_in_rect =
      dispatch_pixel_x_coords_unscaled >= source_rect_unscaled_tl.x &&
      dispatch_pixel_x_coords_unscaled < source_rect_unscaled_br.x;
  [branch] if (dispatch_pixel_index_unscaled.y < source_rect_unscaled_tl.y ||
               dispatch_pixel_index_unscaled.y >= source_rect_unscaled_br.y ||
               !any(x_in_rect)) {
    return;
  }

  uint2 texel_sub_index_scaled =
      xe_group_thread_id.xy & sample_count_and_scale_info.z;

  // Calculate the EDRAM offset of the samples of the pixel.
  // 1 group uses:
  // - 1x resolution, 1x AA - 1x1 tile.
  // - 1x resolution, 2x AA - 1x2 tiles
  //   (group thread ID Y < or >= 8 to choose the tile).
  // - 1x resolution, 4x AA - 2x2 tiles
  //   (same, plus group thread ID X < or >= 10 to choose the tile).
  // - 2x resolution, 1x AA - 0.5x0.5 tiles
  //   (group ID & 1 to choose the quarter of the tile).
  // - 2x resolution, 2x AA - 0.5x1 tiles
  //   (group ID X & 1 to choose the X half of the tile).
  // - 2x resolution, 4x AA - 1x1 tile.
  // In sample info, XY - log2(sample count), ZW - selected sample offset.
  uint2 edram_tile_index, edram_tile_sample_index;
  [branch] if (sample_count_and_scale_info.z != 0u) {
    edram_tile_index = xe_group_id.xy >> (sample_count_and_scale_info.xy ^ 1u);
    edram_tile_sample_index =
        ((xe_group_id.xy & 1u) >> sample_count_and_scale_info.xy) *
        uint2(40u, 8u) +
        (xe_group_thread_id.xy >> 1u <<
         (sample_count_and_scale_info.xy + uint2(2u, 0u)));
  } else {
    uint2 edram_multisample_tile =
        uint2(uint2(10u, 8u) <= xe_group_thread_id.xy) *
        sample_count_and_scale_info.xy;
    edram_tile_index =
        (xe_group_id.xy << sample_count_and_scale_info.xy) +
        edram_multisample_tile;
    edram_tile_sample_index =
        ((xe_group_thread_id.xy - edram_multisample_tile * uint2(10u, 8u)) <<
         (sample_count_and_scale_info.xy + uint2(2u, 0u)));
  }
  edram_tile_sample_index +=
      (xe_edram_tile_sample_dest_info.xx >> uint2(19u, 18u)) & 1u;
  // Force use the lower host texel for the topmost guest texel row to reduce
  // the impact of half-pixel offset.
  uint2 edram_texel_sub_index = texel_sub_index_scaled;
  if (sample_count_and_scale_info.w != 0u) {
    edram_texel_sub_index.y |=
        uint(dispatch_pixel_index_unscaled.y == source_rect_unscaled_tl.y);
  }
  uint4 edram_offsets;
  edram_offsets.x = XeEDRAMOffset64bpp(edram_tile_index,
                                       edram_tile_sample_index,
                                       edram_texel_sub_index);

  // Read four pixels from the EDRAM buffer.
  uint4 pixels_01, pixels_23;
  [branch] if (sample_count_and_scale_info.z != 0u) {
    // 4 host pixels within each sample, thus guest pixels are each 4 dwords
    // away from each other at 1x/2x AA and 8 dwords away at 4x AA.
    edram_offsets.yzw =
        (uint3(32u, 64u, 96u) << sample_count_and_scale_info.x) +
        edram_offsets.x;
    if (sample_count_and_scale_info.w != 0u) {
      // Force use the right host texel for the leftmost guest texel column to
      // reduce the impact of half-pixel offset.
      edram_offsets |=
          (dispatch_pixel_x_coords_unscaled == source_rect_unscaled_tl.x) ? 8u
                                                                          : 0u;
    }
    pixels_01.xy = xe_edram_load_store_source.Load2(edram_offsets.x);
    pixels_01.zw = xe_edram_load_store_source.Load2(edram_offsets.y);
    pixels_23.xy = xe_edram_load_store_source.Load2(edram_offsets.z);
    pixels_23.zw = xe_edram_load_store_source.Load2(edram_offsets.w);
  } else {
    edram_offsets.yzw = uint3(16u, 32u, 48u) + edram_offsets.x;
    // Loaded with the first 2 pixels at 1x and 2x, or the first 1 pixel at 4x.
    pixels_01 = xe_edram_load_store_source.Load4(edram_offsets.x);
    // Loaded with the second 2 pixels at 1x and 2x, or the second 1 pixel at
    // 4x.
    pixels_23 = xe_edram_load_store_source.Load4(edram_offsets.y);
    [branch] if (sample_count_and_scale_info.x != 0u) {
      // Rather than 4 pixels, at 4x, we only have 2 - in xy of each variable
      // rather than in xyzw of pixels_01. Combine and load 2 more.
      pixels_01.zw = pixels_23.xy;
      pixels_23.xy = xe_edram_load_store_source.Load2(edram_offsets.z);
      pixels_23.zw = xe_edram_load_store_source.Load2(edram_offsets.w);
    }
  }

  if ((xe_edram_tile_sample_dest_info & (1u << 23u)) != 0u) {
    // Swap red and blue - all 64bpp formats where this is possible are
    // 16:16:16:16.
    uint format = (xe_edram_tile_sample_dest_info >> 24u) & 15u;
    if (format == 5u || format == 7u) {
      pixels_01 = (pixels_01 & 0xFFFF0000u) | (pixels_01.yxwz & 0xFFFFu);
      pixels_23 = (pixels_23 & 0xFFFF0000u) | (pixels_23.yxwz & 0xFFFFu);
    }
  }

  // Tile the pixels to the shared memory or to the scaled resolve memory.
  uint endian = xe_edram_tile_sample_dest_info >> 20u;
  pixels_01 = XeByteSwap64(pixels_01, endian);
  pixels_23 = XeByteSwap64(pixels_23, endian);
  uint3 texel_offset_unscaled;
  texel_offset_unscaled.xy =
      ((xe_edram_tile_sample_dimensions >> 12u) & 31u) +
      dispatch_pixel_index_unscaled - source_rect_unscaled_tl;
  texel_offset_unscaled.z = (xe_edram_tile_sample_dimensions.x >> 17u) & 7u;
  // If texel_offset_unscaled.x is negative (if the rectangle is not
  // 4-pixel-aligned, for example), the result will be ignored anyway due to
  // x_in_rect.
  uint2 texel_pitch =
      ((xe_edram_tile_sample_dest_info >> uint2(0u, 9u)) & 511u) << 5u;
  uint4 texel_addresses;
  if (texel_pitch.y != 0u) {
    texel_addresses =
        XeTextureTiledOffset3D(texel_offset_unscaled, texel_pitch, 3u);
  } else {
    texel_addresses =
        XeTextureTiledOffset2D(texel_offset_unscaled.xy, texel_pitch.x, 3u);
  }
  texel_addresses =
      ((xe_edram_tile_sample_dest_base + texel_addresses)
       << (sample_count_and_scale_info.z * 2u)
      ) + texel_sub_index_scaled.x * 8u + texel_sub_index_scaled.y * 16u;
  [branch] if (x_in_rect.x) {
    xe_edram_load_store_dest.Store2(texel_addresses.x, pixels_01.xy);
  }
  [branch] if (x_in_rect.y) {
    xe_edram_load_store_dest.Store2(texel_addresses.y, pixels_01.zw);
  }
  [branch] if (x_in_rect.z) {
    xe_edram_load_store_dest.Store2(texel_addresses.z, pixels_23.xy);
  }
  [branch] if (x_in_rect.w) {
    xe_edram_load_store_dest.Store2(texel_addresses.w, pixels_23.zw);
  }
}
