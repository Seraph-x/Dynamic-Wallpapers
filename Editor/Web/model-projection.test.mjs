import test from 'node:test';
import assert from 'node:assert/strict';
import { projectWeightMap } from './model-projection.mjs';
test('weight-map projection retains the existing XY fit, margins and vertex order',()=>{
  const mesh={vertexCount:3,positions:Float32Array.of(-40,20,0,0,0,9,40,-20,0)};
  assert.deepEqual(projectWeightMap(mesh,320,180),[[12,16],[160,90],[308,164]]);
  assert.deepEqual(projectWeightMap({vertexCount:1,positions:Float32Array.of(7,9,2)},320,180),[[160,90]]);
});
